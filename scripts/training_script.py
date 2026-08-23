#!/usr/bin/env python

# Auteur: Felix Ouimet
#
# Entraine un CNN de reconnaissance ASL (Keras/TensorFlow), l'exporte en
# TFLite quantifie int8, pour generer les .mem du Cmod A7-35T.
#
# Dataset: ASL Alphabet (grassknoted), ~3000 vraies photos 200x200 par lettre,
# 24 lettres statiques (pas de J/Z). Remplace Sign Language MNIST, qui ne
# generalisait pas a de vraies photos malgre une bonne precision sur son
# propre jeu de test.
#
# Points cles: meme pretraitement que l'ESP32 (crop_center_resize, bit-exact
# avec camera_preprocess.cpp) ; augmentation pour robustesse cadrage/eclairage ;
# pas de miroir horizontal (ASL chirale) ; evaluation finale hors-dataset
# (danrasband/asl-alphabet-test, autre auteur/camera).
#
# Apres un retrain: relancer export_params.py, puis regenerer
# ESP32/PROJET_ESP32/golden_image.h (logits de l'auto-test au boot).
import os
os.environ["TF_USE_LEGACY_KERAS"] = "1"
os.environ["KERAS_BACKEND"] = "tensorflow"
import sys
import glob
import numpy as np
import tensorflow as tf
import tf_keras as keras
from tf_keras import layers
from tf_keras.preprocessing.image import ImageDataGenerator
import kagglehub
from PIL import Image
from sklearn.model_selection import train_test_split
import tensorflow_model_optimization as tfmot

OUT = "training/final_export"  # folder des sorties, relatif a la racine du repo (comme export_params.py)
CACHE = "training/asl_alphabet_28.npz"  # 28x28 pre-calcules (le decodage des 72k jpg est long)
DATASET_TRAIN = "grassknoted/asl-alphabet"
TESTSET_KAGGLE = "danrasband/asl-alphabet-test"  # jeu hors-dataset (autre auteur)
OUT_W, OUT_H = 28, 28

# Meme mapping que spi_comm.cpp (24 classes, pas de J ni Z: lettres en mouvement)
LETTERS = "ABCDEFGHIKLMNOPQRSTUVWXY"

BATCH, SEED = 128, 2
EPOCHS, QAT_EPOCHS = 30, 6
keras.utils.set_random_seed(SEED)


# Pretraitement: copie fidele de cropCenterAndResize (camera_preprocess.cpp),
# meme arithmetique entiere, pour un 28x28 identique bit a bit a l'ESP32.

def crop_center_resize(src):
    """Crop carre centre puis 28x28 au plus proche voisin."""
    srcH, srcW = src.shape
    crop = min(srcW, srcH)
    cx = (srcW - crop) // 2
    cy = (srcH - crop) // 2
    ys = cy + (np.arange(OUT_H) * crop) // OUT_H
    xs = cx + (np.arange(OUT_W) * crop) // OUT_W
    return src[np.ix_(ys, xs)]


def testset_dir():
    """Jeu hors-dataset Kaggle (870 photos 200x200), telecharge si absent."""
    cache = os.path.expanduser(
        "~/.cache/kagglehub/datasets/danrasband/asl-alphabet-test/versions/1")
    if not os.path.isdir(cache):
        cache = kagglehub.dataset_download(TESTSET_KAGGLE)
    return cache


def load_images_by_letter(root):
    """<root>/**/<LETTRE>/*.jpg -> x uint8 (N,28,28,1), y indices 0-23."""
    xs, ys = [], []
    for li, letter in enumerate(LETTERS):
        files = sorted(glob.glob(os.path.join(root, "**", letter, "*.jpg"),
                                 recursive=True))
        if not files:
            raise RuntimeError(f"aucune image pour la lettre {letter} sous {root}")
        for p in files:
            g = np.asarray(Image.open(p).convert("L"), dtype=np.uint8)
            xs.append(crop_center_resize(g))
        ys.extend([li] * len(files))
        print(f"  {letter}: {len(files)} images")
    return np.stack(xs)[..., np.newaxis], np.array(ys)


def load_data():
    if os.path.exists(CACHE):
        print("cache:", CACHE)
        d = np.load(CACHE)
        x, y = d["x"], d["y"]
    else:
        dataset = kagglehub.dataset_download(DATASET_TRAIN)
        print("dataset:", dataset)
        x, y = load_images_by_letter(dataset)
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        np.savez_compressed(CACHE, x=x, y=y)
        print("cache ecrit:", CACHE)

    # split stratifie: le dataset n'a pas de jeu de test etiquete utilisable
    xtr, xva, ytr, yva = train_test_split(
        x, y, test_size=0.1, stratify=y, random_state=SEED)
    ytr = keras.utils.to_categorical(ytr, len(LETTERS))
    yva = keras.utils.to_categorical(yva, len(LETTERS))
    print(f"train: {len(xtr)}  val: {len(xva)}")
    return xtr, ytr, xva, yva


def load_out_of_dataset():
    """Jeu hors-dataset (autre auteur, autre camera): le vrai juge."""
    return load_images_by_letter(testset_dir())


# augmentation: simule les variations de cadrage/eclairage de la camera.
# horizontal_flip reste OFF (chiralite ASL). rescale applique apres coup:
# le reseau voit du [0,1] comme avant.
def make_augmenter():
    return ImageDataGenerator(
        rescale=1.0 / 255.0,
        rotation_range=15,
        width_shift_range=0.12,
        height_shift_range=0.12,
        zoom_range=0.2,
        shear_range=10,
        brightness_range=(0.65, 1.35),
        fill_mode="nearest")


# architecture et entrainement du modele CNN avec Keras
# (architecture inchangee: le RTL et export_params.py en dependent)

def build_model(xtr, ytr, xva, yva):
    model = keras.Sequential([
        layers.Input(shape=(28, 28, 1), name="img"),
        layers.Conv2D(32, 3, padding="valid", activation="relu", name="conv1"),
        layers.MaxPooling2D(2, name="pool1"),
        layers.Conv2D(64, 3, padding="valid", activation="relu", name="conv2"),
        layers.MaxPooling2D(2, name="pool2"),
        layers.Flatten(name="flat"),
        # Dropout: aucun poids, retire a l'inference -> invisible pour le
        # TFLite, les .mem et le RTL
        layers.Dropout(0.3, name="drop1"),
        layers.Dense(32, activation='relu', name="dense1"),
        # pas d'activation: dense2 sort les logits bruts, comme le RTL
        # (clamp_min=-128) et le protocole SPI (24 logits int8); le softmax
        # vit dans la loss (from_logits=True), argmax cote hote
        layers.Dense(len(LETTERS), name="dense2")
    ], name="asl_cnn")

    model.compile(optimizer='adam',
                  loss=keras.losses.CategoricalCrossentropy(from_logits=True),
                  metrics=['accuracy'])

    print("start model training...")
    flow = make_augmenter().flow(xtr.astype("float32"), ytr,
                                 batch_size=BATCH, seed=SEED)
    model.fit(flow, epochs=EPOCHS, validation_data=(xva / 255.0, yva))
    print("model training completed")

    return model


# Simulation quantization aware training (QAT) du modele CNN avec Keras
def quant_aware_model(model, xtr, ytr, xva, yva):
    quantize_model = tfmot.quantization.keras.quantize_model
    q_aware_model = quantize_model(model)
    # lr reduit: le QAT est un fine-tune, le lr Adam par defaut (1e-3)
    # peut eloigner le modele de l'optimum float
    q_aware_model.compile(optimizer=keras.optimizers.Adam(1e-4),
                          loss=keras.losses.CategoricalCrossentropy(from_logits=True),
                          metrics=['accuracy'])
    q_aware_model.summary()

    flow = make_augmenter().flow(xtr.astype("float32"), ytr,
                                 batch_size=BATCH, seed=SEED)
    q_aware_model.fit(flow, epochs=QAT_EPOCHS, validation_data=(xva / 255.0, yva))

    return q_aware_model


# Comparer les performances du modele original et du modele quantize-aware
def compare_models(model, q_aware_model, xva, yva):
    _, baseline_model_accuracy = model.evaluate(xva / 255.0, yva, verbose=0)
    _, q_aware_model_accuracy = q_aware_model.evaluate(xva / 255.0, yva, verbose=0)

    print('Baseline val accuracy:', baseline_model_accuracy)
    print('Quant val accuracy:', q_aware_model_accuracy)


# Convertir le modele quantize-aware en TFLite avec quantization post-training
def convert_to_tflite(model, filename, x_calib):
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    # echec bruyant si un op n'est pas quantifiable int8 (plutot qu'un
    # repli silencieux en float que le FPGA ne peut pas executer)
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]

    # exige par TFLITE_BUILTINS_INT8; pour un modele QAT les plages apprises
    # priment, la calibration ne sert qu'aux tenseurs sans FakeQuant
    def representative_dataset():
        for i in range(0, min(300, len(x_calib))):
            yield [x_calib[i:i + 1].astype(np.float32) / 255.0]
    converter.representative_dataset = representative_dataset

    tflite_model = converter.convert()
    open(filename, 'wb').write(tflite_model)
    return tflite_model


def evaluate_tflite_model(tflite_model, x, y_idx, name):
    """x: uint8 (N,28,28,1), y_idx: indices 0-23. Meme quantification que
    fpgaQuantize sur l'ESP32 (via scale/zp du modele)."""
    interpreter = tf.lite.Interpreter(model_content=tflite_model)
    interpreter.allocate_tensors()

    input_index = interpreter.get_input_details()[0]
    output_index = interpreter.get_output_details()[0]
    in_scale, in_zero_point = input_index['quantization']
    in_dtype = input_index['dtype']
    info = np.iinfo(in_dtype)

    correct_predictions = 0
    for i in range(len(x)):
        q = np.round(x[i] / 255.0 / in_scale + in_zero_point)
        q = np.clip(q, info.min, info.max).astype(in_dtype)
        interpreter.set_tensor(input_index['index'], q[np.newaxis, ...])
        interpreter.invoke()
        logits = interpreter.get_tensor(output_index['index'])[0]
        if np.argmax(logits) == y_idx[i]:
            correct_predictions += 1
    accuracy = correct_predictions / len(x)
    print(f"TFLite int8 accuracy ({name}): {accuracy:.4f}")
    return accuracy


def main():
    os.makedirs(OUT, exist_ok=True)  # sinon open() crash apres l'entrainement
    xtr, ytr, xva, yva = load_data()
    model = build_model(xtr, ytr, xva, yva)
    q_aware_model = quant_aware_model(model, xtr, ytr, xva, yva)
    compare_models(model, q_aware_model, xva, yva)
    tflite_model = convert_to_tflite(q_aware_model,
                                     os.path.join(OUT, "asl_cnn_qaware.tflite"),
                                     xtr)

    yva_idx = np.argmax(yva, axis=1)
    _, float_acc = model.evaluate(xva / 255.0, yva, verbose=0)
    int8_acc = evaluate_tflite_model(tflite_model, xva, yva_idx,
                                     "validation (meme dataset)")
    if int8_acc < float_acc - 0.02:
        print(f"ATTENTION: int8 {int8_acc:.3f} << float {float_acc:.3f}, "
              f"la quantification perd de l'accuracy (revoir QAT/lr)")

    # Le chiffre qui compte: photos d'un autre auteur, jamais vues.
    # C'est lui qui predit l'accuracy devant la camera.
    xod, yod = load_out_of_dataset()
    evaluate_tflite_model(tflite_model, xod, yod, "hors-dataset")

    print("\nProchaines etapes:")
    print("  python scripts/export_params.py    # nouveaux .mem pour le FPGA")
    print("  mettre a jour ESP32/PROJET_ESP32/golden_image.h (logits de l'auto-test)")


if __name__ == "__main__":
    main()
