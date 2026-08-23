#!/usr/bin/env python
"""
retrain_28x28.py — reentrainement 28x28 avec dataset grassknotted + maison.
Autonome, ne depend d'aucun autre script.
"""
import os
os.environ["TF_USE_LEGACY_KERAS"] = "1"
os.environ["KERAS_BACKEND"] = "tensorflow"

import sys
import numpy as np
import tensorflow as tf
import tf_keras as keras
from tf_keras import layers
from tf_keras.preprocessing.image import ImageDataGenerator
from sklearn.model_selection import train_test_split

INPUT_SIZE = 28
NUM_CLASSES = 24
EPOCHS_FLOAT = 20
EPOCHS_QAT = 6  # QAT est un fine-tune, pas un entrainement complet (cf. training_script.py)
BATCH_SIZE = 64
EXPORT_DIR = "training/final_export_28_maison"
TFLITE_OUT = os.path.join(EXPORT_DIR, "asl_cnn_28_maison.tflite")

NPZ_PATH = "training/asl_alphabet_28.npz"
CSV_PATH = "scripts/dataset_maison.csv"

# meme mapping que spi_comm.cpp / training_script.py (24 classes, pas de J ni Z)
LETTERS = "ABCDEFGHIKLMNOPQRSTUVWXY"
TESTSET_KAGGLE = "danrasband/asl-alphabet-test"  # jeu hors-dataset (autre auteur)


def load_dataset():
    # 1. Charger grassknotted
    if not os.path.exists(NPZ_PATH):
        sys.exit(f"Fichier introuvable : {NPZ_PATH}")
    d = np.load(NPZ_PATH)
    X_all = d["x"].squeeze(-1)  # (72000, 28, 28)
    y_all = d["y"]
    print(f"Grassknotted : {len(X_all)} images")

    # 2. Fusionner avec dataset maison
    if os.path.exists(CSV_PATH):
        import pandas as pd
        df = pd.read_csv(CSV_PATH, header=None)
        X_maison = df.iloc[:, 1:].values.astype(np.uint8).reshape(-1, 28, 28)
        y_maison = df.iloc[:, 0].values
        X_all = np.concatenate([X_all, X_maison], axis=0)
        y_all = np.concatenate([y_all, y_maison], axis=0)
        print(f"Dataset maison : {len(X_maison)} images fusionnees")
    else:
        print(f"Pas de {CSV_PATH} — entrainement sur grassknotted seul")

    print(f"Total : {len(X_all)} images")

    # 3. Split train/test
    X_train, X_test, y_train, y_test = train_test_split(
        X_all, y_all, test_size=0.2, random_state=42, stratify=y_all)

    # 4. ajouter dimension canal, garder en uint8 [0,255]: l'augmentation
    # (make_augmenter) applique rescale=1/255 elle-meme, et la validation
    # est normalisee explicitement plus bas -- pas de division ici.
    X_train = X_train[..., np.newaxis]
    X_test = X_test[..., np.newaxis]

    print(f"Train: {X_train.shape}, Test: {X_test.shape}")
    return X_train, y_train, X_test, y_test


# augmentation: simule les variations de cadrage/eclairage de la camera.
# horizontal_flip reste OFF (chiralite ASL).
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


def build_model():
    """Architecture IDENTIQUE au FPGA 28x28 (sans GAP, avec Flatten)."""
    inputs = keras.Input(shape=(INPUT_SIZE, INPUT_SIZE, 1))
    x = layers.Conv2D(32, 3, activation='relu')(inputs)
    x = layers.MaxPooling2D(2)(x)
    x = layers.Conv2D(64, 3, activation='relu')(x)
    x = layers.MaxPooling2D(2)(x)
    x = layers.Flatten()(x)
    x = layers.Dense(32, activation='relu')(x)
    outputs = layers.Dense(NUM_CLASSES)(x)
    return keras.Model(inputs, outputs)


def quantize_and_export(model, X_train, y_train, X_test, y_test):
    import tensorflow_model_optimization as tfmot
    print("\n--- QAT ---")
    q_model = tfmot.quantization.keras.quantize_model(model)
    # lr reduit: le QAT est un fine-tune, le lr Adam par defaut (1e-3) peut
    # eloigner le modele de l'optimum float (cf. training_script.py)
    q_model.compile(optimizer=keras.optimizers.Adam(1e-4),
                    loss=keras.losses.SparseCategoricalCrossentropy(from_logits=True),
                    metrics=['accuracy'])
    flow = make_augmenter().flow(X_train, y_train, batch_size=BATCH_SIZE, seed=2)
    q_model.fit(flow, epochs=EPOCHS_QAT,
                validation_data=(X_test.astype(np.float32) / 255.0, y_test))
    loss, acc = q_model.evaluate(X_test.astype(np.float32) / 255.0, y_test, verbose=0)
    print(f"\nPrecision QAT test : {acc * 100:.1f}%")

    converter = tf.lite.TFLiteConverter.from_keras_model(q_model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    def rep():
        for i in range(min(500, len(X_train))):
            yield [X_train[i:i + 1].astype(np.float32) / 255.0]
    converter.representative_dataset = rep
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    tflite = converter.convert()
    os.makedirs(EXPORT_DIR, exist_ok=True)
    with open(TFLITE_OUT, "wb") as f:
        f.write(tflite)
    print(f"Modele exporte : {TFLITE_OUT} ({len(tflite) / 1024:.1f} Ko)")
    return tflite


# Evaluation hors-dataset (duplique de training_script.py pour rester autonome)

def crop_center_resize(src):
    srcH, srcW = src.shape
    crop = min(srcW, srcH)
    cx = (srcW - crop) // 2
    cy = (srcH - crop) // 2
    ys = cy + (np.arange(INPUT_SIZE) * crop) // INPUT_SIZE
    xs = cx + (np.arange(INPUT_SIZE) * crop) // INPUT_SIZE
    return src[np.ix_(ys, xs)]


def load_out_of_dataset():
    import glob
    import kagglehub
    from PIL import Image
    cache = os.path.expanduser(
        "~/.cache/kagglehub/datasets/danrasband/asl-alphabet-test/versions/1")
    if not os.path.isdir(cache):
        cache = kagglehub.dataset_download(TESTSET_KAGGLE)
    xs, ys = [], []
    for li, letter in enumerate(LETTERS):
        files = sorted(glob.glob(os.path.join(cache, "**", letter, "*.jpg"),
                                 recursive=True))
        for p in files:
            g = np.asarray(Image.open(p).convert("L"), dtype=np.uint8)
            xs.append(crop_center_resize(g))
        ys.extend([li] * len(files))
    return np.stack(xs)[..., np.newaxis], np.array(ys)


def evaluate_tflite_model(tflite_model, x, y_idx, name):
    interpreter = tf.lite.Interpreter(model_content=tflite_model)
    interpreter.allocate_tensors()
    input_index = interpreter.get_input_details()[0]
    output_index = interpreter.get_output_details()[0]
    in_scale, in_zero_point = input_index['quantization']
    in_dtype = input_index['dtype']
    info = np.iinfo(in_dtype)

    correct = 0
    for i in range(len(x)):
        q = np.round(x[i] / 255.0 / in_scale + in_zero_point)
        q = np.clip(q, info.min, info.max).astype(in_dtype)
        interpreter.set_tensor(input_index['index'], q[np.newaxis, ...])
        interpreter.invoke()
        logits = interpreter.get_tensor(output_index['index'])[0]
        if np.argmax(logits) == y_idx[i]:
            correct += 1
    acc = correct / len(x)
    print(f"TFLite int8 accuracy ({name}): {acc:.4f}")
    return acc


def main():
    print(f"=== Reentrainement 28x28 avec dataset maison ===\n")
    X_train, y_train, X_test, y_test = load_dataset()
    model = build_model()
    model.summary()
    print("\n--- Pre-entrainement float (avec augmentation) ---")
    model.compile(optimizer='adam',
                  loss=keras.losses.SparseCategoricalCrossentropy(from_logits=True),
                  metrics=['accuracy'])
    flow = make_augmenter().flow(X_train, y_train, batch_size=BATCH_SIZE, seed=2)
    model.fit(flow, epochs=EPOCHS_FLOAT,
              validation_data=(X_test.astype(np.float32) / 255.0, y_test))
    loss, acc = model.evaluate(X_test.astype(np.float32) / 255.0, y_test, verbose=0)
    print(f"\nPrecision float : {acc * 100:.1f}%")
    tflite_model = quantize_and_export(model, X_train, y_train, X_test, y_test)

    print("\n--- Evaluation hors-dataset (le chiffre qui compte) ---")
    xod, yod = load_out_of_dataset()
    hors_acc = evaluate_tflite_model(tflite_model, xod, yod, "hors-dataset")
    if hors_acc < 0.5:
        print(f"ATTENTION: {hors_acc*100:.1f}% hors-dataset -- le modele ne "
              f"generalise pas, NE PAS exporter vers le FPGA (export_params.py)")

    print("\nProchaines etapes:")
    print("  python scripts/export_params.py training/final_export_28_maison/asl_cnn_28_maison.tflite")
    print("  mettre a jour ESP32/PROJET_ESP32/golden_image.h (logits de l'auto-test)")
    print("\nTermine.")


if __name__ == "__main__":
    main()
