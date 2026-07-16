# affiche ce qui change entre retrains pour modifier cnn_params.vh si necessaire

def print_vh(layers):
    names = ["CONV1", "CONV2", "DENSE1", "DENSE2"]

    print("---- zero-points ----")
    for name, l in zip(names, layers):
        last = (l is layers[-1])                 # relu partout sauf logits
        clamp = -128 if last else l['zp_out']
        note = "logits bruts (fixe)" if last else "ReLU = zp_out"
        print(f"localparam integer {name}_ZP_IN      = {l['zp_in']};")
        print(f"localparam integer {name}_ZP_OUT     = {l['zp_out']};")
        print(f"localparam integer {name}_CLAMP_MIN  = {clamp};  // {note}")
        print()
