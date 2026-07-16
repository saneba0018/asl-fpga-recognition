#!/usr/bin/env python

# Auteur: Felix Ouimet
# 
# Script pour entrainer un modele CNN pour la reconnaissance de l'alphabet en langue des signes (ASL) avec Keras et Tensorflow
# Exporte le modele en TFLite avec quantization post-training pour l'utiliser sur un FPGA
# Cree fichiers .mem pour importer dans Cmod A7-35T
#
# References:
# https://www.tensorflow.org/model_optimization/guide/quantization/training_example
# https://www.tensorflow.org/model_optimization/guide/quantization/post_training 
# https://www.tensorflow.org/lite/api_docs/python/tf/lite/Interpreter?hl=id 
# https://developers.google.com/edge/litert/conversion/tensorflow/quantization/post_training_integer_quant
# https://medium.com/@tushar.bzp05/building-a-real-time-asl-recognition-system-with-deep-learning-a-complete-tutorial-a72db4a4bdf1v
# https://medium.com/data-science/sign-language-recognition-with-advanced-computer-vision-7b74f20f3442 
# https://victorzhou.com/blog/keras-cnn-tutorial/
# https://ieeexplore.ieee.org/abstract/document/10288799 
import os
os.environ["TF_USE_LEGACY_KERAS"] = "1"
os.environ["KERAS_BACKEND"] = "tensorflow"
import pandas as pd
import glob, math
import numpy as np
import tensorflow as tf
import tf_keras as keras
from tf_keras import layers
import kagglehub
from sklearn.preprocessing import LabelBinarizer
import tensorflow_model_optimization as tfmot

OUT = "training/final_export" #folder des sorties, relatif a la racine du repo (comme export_params.py)
EVAL, BATCH, CALIB_N,SEED = 20, 128, 300, 2
keras.utils.set_random_seed(SEED)

def load_data():

    # fetch csv dataset de Kagglehub (MINST ASL ALPHABET)
    dataset = kagglehub.dataset_download("datamunge/sign-language-mnist")
    print("dataset:", dataset)
    train_path = glob.glob(os.path.join(dataset, "**", "*train*.csv"), recursive=True)[0]
    test_path = glob.glob(os.path.join(dataset, "**", "*test*.csv"), recursive=True)[0]
    
    # load dans pandas
    train_df = pd.read_csv(train_path)
    test_df = pd.read_csv(test_path)

    # separer les features et labels ensuite reshape et normaliser les features
    xtr = train_df.drop(columns=["label"]).values.reshape(-1, 28, 28, 1) / 255.0
    ytr = train_df["label"].values
    xte = test_df.drop(columns=["label"]).values.reshape(-1, 28, 28, 1) / 255.0
    yte = test_df["label"].values

    # encoder les labels en one-hot encoding
    lb = LabelBinarizer()
    ytr = lb.fit_transform(ytr)
    yte = lb.transform(yte)

    return xtr, ytr, xte, yte

# architecture et entrainement du modele CNN avec Keras

def build_model(xtr, ytr, xte, yte):
    model = keras.Sequential([
        layers.Input(shape=(28, 28, 1), name="img"),
        layers.Conv2D(32, 3, padding="valid", activation="relu", name="conv1"),
        layers.MaxPooling2D(2, name="pool1"),
        layers.Conv2D(64, 3, padding="valid", activation="relu", name="conv2"),
        layers.MaxPooling2D(2, name="pool2"),
        layers.Flatten(name="flat"),
        layers.Dense(32, activation='relu', name="dense1"),
        # pas d'activation: dense2 sort les logits bruts, comme le RTL
        # (clamp_min=-128) et le protocole SPI (24 logits int8); le softmax
        # vit dans la loss (from_logits=True), argmax cote hote
        layers.Dense(24, name="dense2")
    ], name="asl_cnn")

    model.compile(optimizer='adam',
                  loss=keras.losses.CategoricalCrossentropy(from_logits=True),
                  metrics=['accuracy'])

    print("start model training...")

    model.fit(xtr, ytr, epochs=20, batch_size=128, validation_data=(xte, yte))
    print("model training completed")
     
    return model


# Simulation quantization aware training (QAT) du modele CNN avec Keras
# non necessaire puisque accuracy presque meme que le modele original, mais utile pour la quantization post-training
def quant_aware_model(model, xtr, ytr, xte, yte):
    quantize_model = tfmot.quantization.keras.quantize_model
    q_aware_model = quantize_model(model)
    q_aware_model.compile(optimizer='adam',
                          loss=keras.losses.CategoricalCrossentropy(from_logits=True),
                          metrics=['accuracy'])
    q_aware_model.summary()
    
    q_aware_model.fit(xtr, ytr, batch_size=BATCH, epochs=4, validation_data=(xte, yte))

    return q_aware_model

# Comparer les performances du modele original et du modele quantize-aware
def compare_models(model, q_aware_model, xte, yte):
    _, baseline_model_accuracy = model.evaluate(xte, yte, verbose=0)
    _, q_aware_model_accuracy = q_aware_model.evaluate(xte, yte, verbose=0)

    print('Baseline test accuracy:', baseline_model_accuracy)
    print('Quant test accuracy:', q_aware_model_accuracy)

# Convertir le modele quantize-aware en TFLite avec quantization post-training
def convert_to_tflite(model, filename):
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    tflite_model = converter.convert()
    open(filename, 'wb').write(tflite_model)
    return tflite_model

def evaluate_tflite_model(tflite_model, xte, yte):
    interpreter = tf.lite.Interpreter(model_content=tflite_model)
    interpreter.allocate_tensors()

    input_index = interpreter.get_input_details()[0]
    output_index = interpreter.get_output_details()[0]
    in_scale, in_zero_point = input_index['quantization']
    in_dtype = input_index['dtype']
   
    correct_predictions = 0
    for i in range(len(xte)):
        q = np.round(xte[i] / in_scale + in_zero_point)
        info = np.iinfo(in_dtype)
        q = np.clip(q, info.min, info.max).astype(in_dtype)
        interpreter.set_tensor(input_index['index'], q[np.newaxis, ...])
        interpreter.invoke()
        logits = interpreter.get_tensor(output_index['index'])[0]
        if np.argmax(logits) == np.argmax(yte[i]):
            correct_predictions += 1
    accuracy = correct_predictions / len(xte)
    print("TFLite int8 model accuracy:", accuracy)




    
def main():
    os.makedirs(OUT, exist_ok=True)  # sinon open() crash apres 24 epochs
    xtr, ytr, xte, yte = load_data()
    model = build_model(xtr, ytr, xte, yte)
    q_aware_model = quant_aware_model(model, xtr, ytr, xte, yte)
    compare_models(model, q_aware_model, xte, yte)
    tflite_model = convert_to_tflite(q_aware_model, os.path.join(OUT, "asl_cnn_qaware.tflite"))
    evaluate_tflite_model(tflite_model, xte, yte)

if __name__ == "__main__":
    main()
