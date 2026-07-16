 ## Théorie
 
 ## Architecture
 
 ## Implémentation FPGA
 
 ### Bases
 
#### Quantification

La quantification est nécessaire dans un réseau de neurones convolutif car
l'entraînement se fait à partir de valeurs représentées en float (32 ou 64 bits). Une multiplication de nombres (u)int8 peut être stockée en
int32, alors qu'une multiplication de float exige un matériel beaucoup
plus coûteux (alignement d'exposants, normalisation, etc.) (Jacob et al.). La représentation en int8
est donc beaucoup plus adaptée aux « edge devices » : sur le XC7A35T, un MAC int8×int8 tient dans une fraction d'un DSP48.

La technique présentée dans Jacob et al. converti un nombre réel r à un
entier q par une transformation affine :

    r ≈ S · (q − Z)

où S et Z sont les paramètres de quantification, fixés par tenseur au moment de
la conversion :

- S (scale) : nombre réel positif
- Z (zero-point) : entier du même type que q. C'est la valeur de q qui correspond exactement à r = 0.

Exemple : représenter la plage réelle [−1.0, 3.0] sur int8 ([−128, 127],
256 pas). L'échelle est S = (3.0 − (−1.0)) / 255 ≈ 0.0157, et le zero-point
est choisi pour que q = −128 corresponde à r = −1.0, soit
Z = −128 + 1.0/S ≈ −64. On vérifie : r = S·(−64 − (−64)) = 0

Déquantification pour retrouver ravec l'interpréteur TFLite :

```python
interp = tf.lite.Interpreter(model_content=tflite_model)
interp.allocate_tensors()
S, Z = interp.get_input_details()[0]["quantization"]
r = S * (q.astype(np.int32) - Z)                        # dequantize
```

##### Contraintes de la quantification int8 de TFLite

La spécification 8 bits de TFLite/LiteRT a des particularités selon le
rôle du tenseur:

Tenseurs:

- Activations: int8, quantification avec Z variable (libre), un couple (S, Z) par tenseur.
- Poids: int8, quantification avec Z = 0, un S par canal de sortie (output channel)
- Biais: int32, S = S_in · S_w, Z = 0


L'accumulateur int32 d'une couche est donc dans les unités S_in · S_w, alors
que la couche suivante attend de l'int8 dans ses propres unités S_out. Le
passage de l'un à l'autre (multiplication par le facteur effectif M, arrondi,
ajout de Z_out, clamp) est la **requantification**.

Le **facteur effectif** M sort directement de l'arithmétique des scales. En
réel, un canal de sortie (output channel) calcule :

    r_out = Σ r_in · r_w + r_bias

En remplaçant chaque r par sa forme quantifiée S · (q − Z) (les poids et le
biais ayant Z = 0) :

    S_out · (q_out − Z_out) = Σ S_in·(q_in − Z_in) · S_w·q_w + S_in·S_w·q_bias
                            = S_in·S_w · [ Σ (q_in − Z_in)·q_w + q_bias ]
                            = S_in·S_w · acc

où acc est exactement l'accumulateur entier du MAC. En isolant q_out :

    q_out = M · acc + Z_out,   avec   M = S_in · S_w / S_out

M est donc une constante qui condense les trois scales d'une
couche. C'est le « multiplicateur » défini par Jacob et al. éq. (5),
M := S₁S₂/S₃, avec S₁ = S_in, S₂ = S_w, S₃ = S_out dans nos variables. Elle
effectue la conversion entre les unités de l'accumulateur et celles du tenseur
de sortie. Il y en a un par canal
de sortie quand les poids sont quantifiés par canal. Comme M est réel mais que
le FPGA ne calcule qu'en entier, il est appliqué via la décomposition
M = m · 2⁻³¹ · 2⁻ⁿ (m entier Q31, n = shift) : c'est la forme normalisée
M = 2⁻ⁿ · M₀ avec M₀ ∈ [0.5, 1) de l'équation (6) du papier, où `m` est l'entier int32 le plus proche de 2³¹ · M₀. Ce calcul est détaillé aux sections « Export des
paramètres » et « requantize.v ».

Pour notre modèle : l'entrée a comme paramètres S = 1/255 et Z = −128, de sorte que l'int8 d'entrée est simplement l'octet de la caméra XOR 0x80. La chaîne
des zero-points d'activation actuelle est −128 → −41 → −81 → −114 → 62
(conv1 → conv2 → dense1 → dense2).

##### TensorFlow

Framework de construction, d'entraînement et d'export de modèles d'IA, organisé
autour du calcul sur tenseurs. Un tenseur est un tableau n-dimensionnel typé :

- rank-0 : scalaire
- rank-1 : vecteur (1D)
- rank-2 : matrice (2D)
- rank-3 et + : tableaux 3D et plus

(https://www.tensorflow.org/guide/tensor)

4 composantes de l'écosystème sont utilisées :

- Keras : définition de l'architecture
  (Conv2D, MaxPooling2D, Dense) et entraînement float32 dans training_script.py
- TensorFlow Model Optimization (tfmot) : le *quantization-aware
  training*.
- TFLiteConverter : converti le modèle QAT en un fichier .tflite entièrement
  int8 poids int8 par canal, biais int32, et les (S, Z) de
  chaque tenseur.
- LiteRT interpreter: Extraction des paramètres des tenseurs en utilisant le nouvel API de Google.
  
 ### Training
 
Nous utilisons la même architecture et outils qui ont été définis dans le cahier des charges.
 
 ### Export des paramètres

Le script `scripts/export_params.py` fait la conversion des paramètres entre le modèle entraîné etle RTL : il extrait du fichier `asl_cnn_qaware.tflite` les poids, les biais et
les paramètres de quantification, puis génère les fichiers `.mem` chargés dans
les ROM du FPGA (via `$readmemh`).

#### Extraction depuis le .tflite

L'extraction utilise l'interpréteur LiteRT (`ai_edge_litert.Interpreter`, même
API que `tf.lite.Interpreter`). Les tenseurs sont repérés par leur index dans
le graphe. Ces indices ont été identifiés avec Netron.app et sont écrits
dans la table `LAYERS`, un quadruplet (entrée, poids, biais, sortie) par
couche :

| Couche | entrée | poids | biais | sortie |
|--------|--------|-------|-------|--------|
| conv1  | 5      | 6     | 2     | 7      |
| conv2  | 8      | 9     | 1     | 10     |
| dense1 | 12     | 13    | 4     | 14     |
| dense2 | 14     | 15    | 3     | 16     |

Pour chaque couche, `extract()` récupère sept valeurs. Elles reprennent les
paramètres S et Z du schéma r ≈ S · (q − Z) de la section « Quantification »,
appliqués aux trois tenseurs de la couche (entrée, poids, sortie) :

- `s_in` : scale du tenseur d'entrée. Entre dans le calcul du facteur effectif M = S_in · S_w / S_out.
- `zp_in` : zero-point du tenseur d'entrée. C'est la valeur int8 qui
  représente le réel 0 en entrée; le MAC la soustrait de chaque activation
  (`act − zp_in` dans `mac_unit.v`) pour ramener le calcul autour du vrai zéro.
- `s_w` : scale(s) des poids. Tableau d'un seul élément si la couche a un
  scale global, ou d'un scale par canal de sortie (quantification par canal,
  cf. « Contraintes du schéma int8 de TFLite »). Les poids étant symétriques,
  ils n'ont pas de zero-point (Z = 0).
- `weights` : les poids int8 eux-mêmes, dans le layout du tenseur TFLite
  (conv : [canal de sortie, hauteur, largeur, canal d'entrée]; dense :
  [sortie, entrée]). Aplatis tels quels dans `weights.mem`.
- `bias` : les biais int32, un par canal de sortie. Déjà exprimés dans les
  unités de l'accumulateur (S forcé à S_in · S_w, cf. contraintes TFLite), ils
  s'additionnent donc directement au premier terme du MAC sans conversion.
- `s_out` : scale du tenseur de sortie. Dénominateur du facteur effectif M;
  c'est lui qui ramène l'accumulateur int32 dans l'échelle int8 de la couche
  suivante.
- `zp_out` : zero-point du tenseur de sortie. Ajouté après la
  requantification (`relu_clamp`) pour replacer le résultat dans la
  représentation du tenseur de sortie; sert aussi de borne basse du clamp pour
  les couches ReLU.

Les scales ne sont pas dans les fichiers `.mem`. Il n'y a que les
poids, les biais et le couple (m, shift) qui encode M. Les zero-points, eux,
deviennent des constantes de `cnn_params.vh`.

#### Génération des fichiers .mem

`convert_mem()` écrit quatre fichiers dans `vivado/conv_accel/mem/`, toutes couches concaténées dans l'ordre conv1 → conv2 → dense1 → dense2 :

- `weights.mem` : poids int8 aplatis, un octet hexadécimal par ligne ;
- `bias.mem` : biais int32, 8 chiffres hexadécimaux par ligne ;
- `mult.mem` : multiplicateur de requantification m (entier Q31, int32) ;
- `shift.mem` : décalage n (int8), un couple (m, n) par canal de sortie.

Le couple (m, n) encode le facteur effectif M = S_in · S_w / S_out de chaque
canal (le S_w par canal est utilisé quand la couche en a plusieurs). C'est la
décomposition M = m · 2⁻³¹ · 2⁻ⁿ introduite à la section « Quantification » et
utilisée par `requantize.v`.

#### quantize_multiplier : conversion de float à Q31 + shift

##### Le format Q31 (1.31)

Q31 est un format à virgule fixe fractionnaire sur 32 bits, aussi noté 1.31 :
1 bit pour la partie entière, 31 bits pour la partie fractionnaire (spec
Microchip). Le bit de poids fort est le bit de signe (complément à deux) et la
virgule est implicite juste après lui. Un entier q interprété en Q31
représente donc le réel :

    r = q / 2³¹

- Plage : −1.0 (0x80000000) à 1 − 2⁻³¹ ≈ +0.9999999995 (0x7FFFFFFF).
- Résolution : 2⁻³¹ ≈ 4.66 × 10⁻¹⁰ (le pas entre deux valeurs consécutives).
- Exemple (spec Microchip) : l'entier 1610612736 (0x60000000) vaut 0.75 en
  Q31 (bits 2⁻¹ + 2⁻² = 0.5 + 0.25).

Dans notre cas, `mult.mem` stocke la mantisse normalisée M₀ ∈ [0.5, 1) en
Q31 : m = round(2³¹ · M₀), donc m ∈ [2³⁰, 2³¹). m est toujours positif (bit de signe à 0) et son bit 30 est toujours à 1. Le format seul ne couvre que [−1, 1) : les valeurs de M plus petites (jusqu'à ~2⁻¹²) sont atteintes par le décalage à droite additionnel n (`shift.mem`), d'où le couple « Q31 + shift ».

##### Justification de représentation

M est le seul nombre réel qui survit à la quantification en modèle TFLite : tout le reste du calcul est déjà en entiers. Nous choisissons de le représenter en Q31 + shift plutôt qu'en float pour répondre à 4 contraintes :

- Coût matériel : le XC7A35T n'a pas de FPU. Une multiplication flottante serait 	beaucoup trop complexe. Avec Q31 + shift, la requantification se réduit à une multiplication entière 32×32 → 64 bits suivie d'un décalage arithmétique, ce qui est beaucoup plus efficace en espace et en temps.
- Précision : un format fixed-point à virgule fixe unique gaspillerait des
bits, car les M du modèle s'étalent sur ~2⁻⁷ à 2⁻¹² (d'où la plage du shift).
La normalisation par `frexp` garantit une mantisse dans [2³⁰, 2³¹) quel que
soit l'ordre de grandeur de M : les 31 bits de précision sont toujours
pleinement utilisés (erreur relative ~2⁻³¹, négligeable devant le pas de
quantification int8). C'est l'équivalent entier d'un flottant évalué sans hardware pour unités à points flottants.
- Espace de stockage : 32 bits (m) + un petit entier (n, 5 bits suffisent)
par canal de sortie, soit 152 entrées dans `mult.mem`/`shift.mem`.
- Conformité : c'est exactement le schéma de TFLite/gemmlowp (Jacob et
al., Parra et al.). Garder la même décomposition permet la comparaison avec la référence afin d'assurer une exactitude des opérations du FPGA.

##### Calcul

TensorFlow calcule cette décomposition à l'intérieur de l'interpréteur
(`QuantizeMultiplier`, `tensorflow/lite/kernels/internal/quantization_util.cc`)
mais ne l'expose pas comme appel de librairie ; la fonction est donc réécrite
dans le script :

1. `math.frexp(M)` sépare M en une mantisse q ∈ [0.5, 1) et un exposant de 2 ;
2. la mantisse est mise à l'échelle Q31 (`q · 2³¹`) et arrondie *half away
   from zero* (`round_half_away`, pour reproduire `TfLiteRound` et éviter le
   biais du round-half-even de Python sur un 0.5 exact) ;
3. si l'arrondi pousse la mantisse à exactement 2³¹, elle est divisée par 2 et l'exposant incrémenté ;
4. le shift retourné est n = −exposant (convention décalage à droite, puisque
   M < 1).

Ce calcul correspond exactement aux modules Verilog `srdhm`
(SaturatingRoundingDoublingHighMul) et `round_shift` côté FPGA. Des assertions
vérifient les invariants supposés par le RTL : M ∈ (0, 1), multiplicateur
normalisé (2³⁰ ≤ m < 2³¹) et shift dans la plage 7 ≤ n ≤ 12 vérifiée du RTL :
un retrain qui sortirait de cette plage ferait échouer l'export plutôt que de
produire une inférence silencieusement fausse.

#### Constantes pour cnn_params.vh

Enfin, `write_vh.py` (`print_vh`) affiche les `localparam` susceptibles de
changer entre deux réentraînements, à reporter manuellement dans
`cnn_params.vh` : pour chaque couche, `ZP_IN`, `ZP_OUT` et `CLAMP_MIN`. Le
clamp bas vaut Z_out pour les couches suivies d'un ReLU fusionné (le zéro réel
correspond à q = Z_out), et −128 pour la dernière couche (logits bruts, plage
int8 complète).

 ### Modules
 
 #### requantize.v

Chaîne combinatoire en trois étages, représentative de l'Appendix A de Parra et al. :

1. `srdhm` (*SaturatingRoundingDoublingHighMul*, Algorithm A1) : produit
   64 bits acc × m, nudge d'arrondi (+2³⁰ si positif, 1−2³⁰ sinon), division
   par 2³¹ tronquée vers zéro. La saturation du cas a = b = INT32_MIN de
   l'algorithme est omise car m est toujours positif.
2. `round_shift` (*RoundingDivideByPOT*, Algorithm A2) : arrondi de q / 2ⁿ
   avec la convention exacte de gemmlowp (`threshold = (mask >> 1) + (q < 0)`) :
   les ties s'arrondissent en s'éloignant de zéro.
3. `relu_clamp` : ajout de Z_out puis clamp à [CLAMP_MIN, 127] (CLAMP_MIN =
   Z_out pour les couches ReLU, −128 pour les logits).

##### Choix : double rounding (papier) vs single rounding (LiteRT moderne)

Le pipeline srdhm vers round_shift est le *double arrondi* historique de
gemmlowp (librairie de multiplication de matrices de Google), celui décrit par Jacob et al. et Parra et al. TFLite/LiteRT utilisent maintenant, par défaut, un *single rounding* afin de régler quelques erreurs (voir https://github.com/tensorflow/tensorflow/issues/25087 et )
(`TFLITE_SINGLE_ROUNDING`) fourni par la librairie ruy, successeur à gemmlowp. La formule résultatnte est `r = (acc·m + 2³⁰⁺ⁿ) ≫ (31+n)`.
 
 #### mac_unit.v
 
 Ce module multiplie et accumule le produit des activations avec les poids du filtre fournis par l'entraînement.
 Multiplication: le produit est le résultat de l'activation soustrait au zero-point, ensuite mutliplié par le poids.
 Addition: Dans le cas du premier terme, le biais est additionné au produit. Par après, le produit est additionné au total.
 
 #### conv_engine.v
 
 Ce module est utilisé pour les calculs des couches conv1, conv2, dense1, dense2. Il effectue la convolution, soit l'opération MAC ainsi que la requantification.
 
Par exemple, pour 2 pixels de sortie:  
  
Si s_valid (alors s_valid = 1), l'unité de MAC effectue les opérations. 
 
 #### pool_engine.v
 
 Effectue MaxPooling sur les données.
 
 #### Mémoire
 
 
 
 ##### param_rom.v
 
 
 
 ##### act_ram.v
 
 
 
 #### Assemblage des couches 
 
 
 
 
 ## Sources
 
 Jacob et al., Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference, CVPR 2018 : the scheme, QAT, fused ReLU. https://arxiv.org/abs/1712.05877
LiteRT 8-bit quantization. https://developers.google.com/edge/litert/models/quantization_spec
gemmlowp fixedpoint.h : reference SaturatingRoundingDoublingHighMul / RoundingDivideByPOT. https://github.com/google/gemmlowp/blob/master/fixedpoint/fixedpoint.h
ruy apply_multiplier.cc https://github.com/google/ruy/blob/master/ruy/apply_multiplier.cc
TFLite common.h / quantization_util.cc : MultiplyByQuantizedMultiplier and QuantizeMultiplier. https://github.com/tensorflow/tensorflow/blob/master/tensorflow/lite/kernels/internal/common.h
Parra et al., A Methodology and Open-Source Tools to Implement CNNs Quantized with TensorFlow Lite on FPGAs, Electronics 2023 : the FPGA methodology, Appendix A. https://doi.org/10.3390/electronics12204367
Microchip, MPLAB XC-DSC Libraries Reference Manual, §5.1.2.3 « Q31 (1.31) Format » : définition du format Q31. https://onlinedocs.microchip.com/oxy/GUID-70ACD6B0-A33F-4653-B192-8465EAD1FD98-en-US-11/GUID-889092D2-E1E4-4491-ABDB-47CEEBA41E1D.html
https://poloclub.github.io/cnn-explainer/


