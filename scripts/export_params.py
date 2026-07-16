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

# Indices des tenseurs dans asl_cnn_qaware.tflite: (entree, poids, biais, sortie) pour conv1, conv2, dense1, dense2.
# Extrait de Netron.app
# A verifier et modifier apres un retrain.
LAYERS = [
    (5,  6,  2, 7),    # conv1
    (8,  9,  1, 10),   # conv2
    (12, 13, 4, 14),   # dense1
    (14, 15, 3, 16),   # dense2
]


def extract():
    interp = Interpreter(model_path="training/final_export/asl_cnn_qaware.tflite")
    interp.allocate_tensors()
    tensors = {t['index']: t for t in interp.get_tensor_details()}

    # debug print pour retrouver les indices apres un retrain:
    # for t in tensors.values():
    #     print(t['index'], t['name'], t['shape'], t['dtype'])

    def q(i):
        return tensors[i]['quantization_parameters']

    layers = []
    for i_in, i_w, i_b, i_out in LAYERS:
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
    assert 7 <= shift <= 12, f"shift {shift} hors plage verifiee du RTL"
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
