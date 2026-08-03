# export_params.py: extrait poids, biais et parametres de quantification du
# .tflite et genere les fichiers .mem pour le FPGA. Lancer depuis la racine du repo.
#
# References:
# https://www.tensorflow.org/api_docs/python/tf/lite/Interpreter (get_tensor_details, get_tensor)
# https://developers.google.com/edge/litert/models/quantization_spec (S_bias = S_in * S_w)
# https://netron.app/ (visualiser le modele et retrouver les indices des tenseurs)

import os
import math
import numpy as np
from write_vh import print_vh
from ai_edge_litert.interpreter import Interpreter  # meme API que tf.lite.Interpreter, nouvelle version

# Les indices des tenseurs changent a chaque conversion TFLite: on les
# retrouve par leur forme, connue puisque l'architecture est figee
# (28x28 -> conv 32x3x3 -> pool -> conv 64x3x3 -> pool -> dense 32 -> dense 24).
# En cas d'ambiguite le script dump tous les tenseurs et s'arrete: remplir
# alors LAYERS_OVERRIDE a la main (via Netron.app) comme avant.
LAYERS_OVERRIDE = None  # ex: [(5, 6, 2, 7), (8, 9, 10, 11), ...]

# (poids, entree, sortie) attendus par couche; None = entree/sortie du modele
ARCH = [
    ("conv1",  (32, 3, 3, 1),  None,            (1, 26, 26, 32)),
    ("conv2",  (64, 3, 3, 32), (1, 13, 13, 32), (1, 11, 11, 64)),
    ("dense1", (32, 1600),     (1, 1600),       (1, 32)),
    ("dense2", (24, 32),       (1, 32),         None),
]


def dump_tensors(tensors):
    for t in tensors:
        qp = t['quantization_parameters']
        print(t['index'], t['name'], tuple(t['shape']), t['dtype'].__name__,
              f"scales:{len(qp['scales'])}")


def find_unique(tensors, pred, what):
    m = [t for t in tensors if pred(t)]
    if len(m) != 1:
        dump_tensors(tensors)
        raise RuntimeError(f"{what}: {len(m)} candidats au lieu de 1 -- "
                           f"remplir LAYERS_OVERRIDE avec les indices ci-dessus")
    return m[0]


def resolve_layers(interp, details):
    io_in = interp.get_input_details()[0]['index']
    io_out = interp.get_output_details()[0]['index']

    resolved = []
    for name, w_shape, in_shape, out_shape in ARCH:
        w = find_unique(details,
                        lambda t: t['dtype'] == np.int8
                        and tuple(t['shape']) == w_shape,
                        f"{name} poids {w_shape}")

        def act(shape, io, what):
            if shape is None:
                return next(t for t in details if t['index'] == io)
            return find_unique(details,
                               lambda t: t['dtype'] == np.int8
                               and tuple(t['shape']) == shape,
                               f"{name} {what} {shape}")

        t_in = act(in_shape, io_in, "entree")
        t_out = act(out_shape, io_out, "sortie")

        # le biais se reconnait a sa forme (C,) int32 ET a son echelle:
        # s_bias = s_in * s_w par canal (spec de quantification TFLite).
        # La forme seule est ambigue (biais conv1 et dense1: 32 tous les deux).
        s_in = t_in['quantization_parameters']['scales'][0]
        s_w = w['quantization_parameters']['scales']
        n_out = w_shape[0]

        def bias_match(t):
            if t['dtype'] != np.int32 or tuple(t['shape']) != (n_out,):
                return False
            s_b = t['quantization_parameters']['scales']
            if len(s_b) not in (1, n_out):
                return False
            return np.allclose(s_b, s_in * s_w, rtol=1e-3)

        b = find_unique(details, bias_match, f"{name} biais ({n_out},)")
        resolved.append((t_in['index'], w['index'], b['index'], t_out['index']))
        print(f"  {name}: in={t_in['index']} w={w['index']} "
              f"b={b['index']} out={t_out['index']}")
    return resolved


def extract():
    interp = Interpreter(model_path="training/final_export/asl_cnn_qaware.tflite")
    interp.allocate_tensors()
    details = interp.get_tensor_details()
    tensors = {t['index']: t for t in details}

    layer_idx = LAYERS_OVERRIDE or resolve_layers(interp, details)

    def q(i):
        return tensors[i]['quantization_parameters']

    layers = []
    for i_in, i_w, i_b, i_out in layer_idx:
        l = {
            's_in':   q(i_in)['scales'][0],
            'zp_in':  int(q(i_in)['zero_points'][0]),
            's_w':    q(i_w)['scales'],
            'weights': interp.get_tensor(i_w),
            'bias':    interp.get_tensor(i_b),
            's_out':  q(i_out)['scales'][0],
            'zp_out': int(q(i_out)['zero_points'][0]),
        }
        layers.append(l)
    return layers


# map sur fpga .mem
def convert_mem(layers):
    print("------ start creating mem files -------")
    os.makedirs("vivado/conv_accel/mem", exist_ok=True) # creation folder, path doit etre valide
    with open("vivado/conv_accel/mem/weights.mem", "w") as f_weights, \
         open("vivado/conv_accel/mem/bias.mem", "w")    as f_bias, \
         open("vivado/conv_accel/mem/mult.mem", "w")    as f_mult, \
         open("vivado/conv_accel/mem/shift.mem", "w")   as f_shift:
        for l in layers:

            # write weights
            for v in l['weights'].flatten():
                f_weights.write(f"{int(v) & 0xFF:02x}\n") #int8, bitwise, 2 hex avec 0 padding

            n_output_channels = len(l['bias'])
            for oc in range (n_output_channels):

                # trouver s_w (weight scale). des layers en utilisent seulement 1, d'autre plus
                if len(l['s_w']) > 1:
                    s_w = l['s_w'][oc]
                else:
                    s_w = l['s_w'][0]

                # input scale, weight scale et output scale sur 1 nombre float (voir Jacob et al.)
                # converti en float64 pour operation
                effective_scale = (float(l['s_in'] )* float(s_w) / float(l['s_out']))

                # convert scale float to Q31 + shift
                m, shift = quantize_multiplier(effective_scale)

                f_bias.write(f"{int(l['bias'][oc]) & 0xFFFFFFFF:08x}\n") #int32, bitwise, 8 hex avec 0 padding
                f_mult.write(f"{m:08x}\n")  #int32...
                f_shift.write(f"{shift:02x}\n") #int8...

    print("------ end -------")


# Util pour convertir de float a fixed point Q31 et shift
# Correspond aux modules verilog srdhm et round_shift
# Les scales (mult) sont en float alors on doit les convertir, tensorflow le fait dans le modele, mais n'a pas d'appel librairie pour cela
# la fonction doit donc etre reecrite
# source: QuantizeMultiplier, tensorflow/lite/kernels/internal/quantization_util.cc
# (https://github.com/tensorflow/tensorflow/blob/master/tensorflow/lite/kernels/internal/quantization_util.cc)
def quantize_multiplier(M):

    if M == 0.0:                       # if(double_multiplier==0.)
        return 0, 0                    # on retourne

    # frexp convertit un float en une fraction (mantisse) [q] et entier exposant de 2 [exp]
    q, exp = math.frexp(M)             # std::frexp(double_multiplier, shift)
    q_fixed = int(round_half_away(q * (1 << 31)))   # TfLiteRound
    assert q_fixed <= (1 << 31)
    if q_fixed == (1 << 31):           # l'arrondi pousse q a 1.0
        q_fixed //= 2
        exp += 1

    if exp < -31:                      # arrondissement si M < ~2^-31 --> 0
        return 0, 0

    # checks
    shift = -exp                       # convention right-shift determinee
    assert 0 < M < 1.0
    assert (1 << 30) <= q_fixed < (1 << 31), "multiplier non normalise"
    assert 7 <= shift <= 12, (
        f"shift {shift} hors plage verifiee du RTL: un retrain a change les "
        f"echelles. Verifier round_shift dans requantize.v pour cette valeur "
        f"(tb_conv_engine) puis elargir la plage ici.")
    return q_fixed, shift


# empeche erreur sur un 0.5 exact
def round_half_away(x):
    if x >= 0:
        return math.floor(x + 0.5)
    else:
       return math.ceil(x - 0.5)

def main():
    layers = extract()
    convert_mem(layers)
    print_vh(layers)
    print("end program")


if __name__ == "__main__":
    main()
