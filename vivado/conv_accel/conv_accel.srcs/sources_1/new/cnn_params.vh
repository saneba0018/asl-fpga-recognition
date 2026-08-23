`ifndef CNN_PARAMS_VH
`define CNN_PARAMS_VH

// Legende des suffixes :
//   _H_IN, _W_IN   hauteur/largeur du tensor d'entree de l'etage
//   _H_OUT, _W_OUT hauteur/largeur du tensor de sortie
//   _C_IN, _C_OUT  canaux d'entree/sortie (dense: C_IN = longueur aplatie)
//   _C             canaux d'un pool (inchange entre entree et sortie)
//   _K             cote du noyau: 3 = conv 3x3, 1 = dense traite en conv 1x1
//   _WOFF          offset de base dans la ROM poids (bytes)
//   _OC_BASE       index de base dans les ROMs bias/mult/shift (canal global 0..151)
//   _ZP_IN         zero-point du tensor d'entree (soustrait dans le MAC)
//   _ZP_OUT        zero-point du tensor de sortie (ajoute apres requant)
//   _CLAMP_MIN     borne basse du clamp: = ZP_OUT si ReLU fusionne, -128 sinon

// Seuls ZP_IN/ZP_OUT/CLAMP_MIN peuvent changer a un retrain

// globals
localparam integer WEIGHT_NUM = 70688;  //nb lignes // valeurs
localparam integer CHANNEL_NUM = 152;  //nb bias, mult, shift

//conv1
localparam integer CONV1_H_IN = 28;
localparam integer CONV1_W_IN = 28;
localparam integer CONV1_C_IN = 1;
localparam integer CONV1_H_OUT = 26;
localparam integer CONV1_W_OUT = 26;
localparam integer CONV1_C_OUT = 32;
localparam integer CONV1_K = 3;
localparam integer CONV1_WOFF = 0;
localparam integer CONV1_OC_BASE = 0;
localparam integer CONV1_ZP_IN = -128;
localparam integer CONV1_ZP_OUT = -123;
localparam integer CONV1_CLAMP_MIN = -123;  // ReLU fusionne = zp_out

//pool1
localparam integer POOL1_H_IN = 26;
localparam integer POOL1_W_IN = 26;
localparam integer POOL1_C = 32;
localparam integer POOL1_H_OUT = 13;
localparam integer POOL1_W_OUT = 13;

//conv2
localparam integer CONV2_H_IN = 13;
localparam integer CONV2_W_IN = 13;
localparam integer CONV2_C_IN = 32;
localparam integer CONV2_H_OUT = 11;
localparam integer CONV2_W_OUT = 11;
localparam integer CONV2_C_OUT = 64;
localparam integer CONV2_K = 3;
localparam integer CONV2_WOFF = 288;
localparam integer CONV2_OC_BASE = 32;
localparam integer CONV2_ZP_IN = -123;
localparam integer CONV2_ZP_OUT = -127;
localparam integer CONV2_CLAMP_MIN = -127;

//pool2
localparam integer POOL2_H_IN = 11;
localparam integer POOL2_W_IN = 11;
localparam integer POOL2_C = 64;
localparam integer POOL2_H_OUT = 5;
localparam integer POOL2_W_OUT = 5;

//dense1
localparam integer DENSE1_C_IN = 1600;
localparam integer DENSE1_C_OUT = 32;
localparam integer DENSE1_K = 1;
localparam integer DENSE1_WOFF = 18720;
localparam integer DENSE1_OC_BASE = 96;
localparam integer DENSE1_ZP_IN = -127;
localparam integer DENSE1_ZP_OUT = -128;
localparam integer DENSE1_CLAMP_MIN = -128;

//dense2
localparam integer DENSE2_C_IN = 32;
localparam integer DENSE2_C_OUT = 24;
localparam integer DENSE2_K = 1;
localparam integer DENSE2_WOFF = 69920;
localparam integer DENSE2_OC_BASE = 128;
localparam integer DENSE2_ZP_IN = -128;
localparam integer DENSE2_ZP_OUT = 52;
localparam integer DENSE2_CLAMP_MIN = -128;  // logits bruts

`endif
