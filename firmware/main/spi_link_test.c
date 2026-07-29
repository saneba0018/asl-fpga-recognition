//-----------------------------------------------------------------------------
// spi_link_test.c — validation du lien SPI ESP32-S3 <-> Cmod A7
//
// Cible : XIAO ESP32-S3 Sense, ESP-IDF 5.1.7
// A utiliser avec le bitstream top_mock sur le FPGA.
//
// Cablage (silkscreen XIAO -> GPIO -> broche FPGA) :
//   D8  -> GPIO7  -> A16  SCK
//   D10 -> GPIO9  -> M3   MOSI
//   D9  -> GPIO8  -> L3   MISO
//   D3  -> GPIO4  -> K3   CS_n
//   D6  -> GPIO43 -> K18  o_ready       <-- voir avertissement ci-dessous
//   GND -> GND
//
// AVERTISSEMENT GPIO43 : c'est aussi UART0 TX. Si la console est routee sur
// UART0, cette broche est occupee et la lecture de o_ready sera fausse.
// Verifier dans sdkconfig : CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y
// Sinon, recabler sur D5 = GPIO6 et changer PIN_READY ci-dessous.
//-----------------------------------------------------------------------------

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_log.h"
#include "esp_attr.h"

#define PIN_SCLK GPIO_NUM_7   // D8
#define PIN_MOSI GPIO_NUM_9   // D10
#define PIN_MISO GPIO_NUM_8   // D9
#define PIN_CS GPIO_NUM_4     // D3
#define PIN_READY GPIO_NUM_43 // D6  (basculer sur GPIO_NUM_6 = D5 si besoin)

#define CMD_LOAD_WEIGHTS 0x01
#define CMD_SEND_IMAGE 0x02
#define CMD_START_CONV 0x03
#define CMD_READ_RESULT 0x04
#define CMD_GET_STATUS 0x05

static const char *TAG = "spi_link";
static spi_device_handle_t fpga;
static int pass = 0, fail = 0;
static int link_dead = 0;

// Tampons statiques alignes sur 32 bits.
// Le DMA d'ESP-IDF exige un alignement mot ; des tableaux uint8_t sur la
// pile ne le garantissent pas. Le statique evite aussi de deborder la pile
// de la tache principale (3584 octets par defaut) avec des blocs de 784.
WORD_ALIGNED_ATTR static uint8_t txbuf[800];
WORD_ALIGNED_ATTR static uint8_t rxbuf[800];

//=============================================================================
// Primitives
//=============================================================================

static void spi_init(void)
{
    spi_bus_config_t bus = {
        .mosi_io_num = PIN_MOSI,
        .miso_io_num = PIN_MISO,
        .sclk_io_num = PIN_SCLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 1024};
    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO));

    spi_device_interface_config_t dev = {
        .clock_speed_hz = 1000000, // 1 MHz : plafond f_clk/4 avec sysclk 12 MHz
        .mode = 0,                 // CPOL=0, CPHA=0
        .spics_io_num = PIN_CS,
        .queue_size = 4};
    ESP_ERROR_CHECK(spi_bus_add_device(SPI2_HOST, &dev, &fpga));
}

static void ready_init(void)
{
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << PIN_READY,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = 0,
        .pull_down_en = 0,
        .intr_type = GPIO_INTR_DISABLE};
    ESP_ERROR_CHECK(gpio_config(&io));
}

static void xfer(const uint8_t *tx, uint8_t *rx, size_t n)
{
    spi_transaction_t t = {
        .length = n * 8,
        .tx_buffer = tx,
        .rx_buffer = rx};
    ESP_ERROR_CHECK(spi_device_transmit(fpga, &t));
}

// GET_STATUS : 3 octets. MISO -> [ignore][ignore][status]
static uint8_t get_status(void)
{
    memset(txbuf, 0, 4);
    txbuf[0] = CMD_GET_STATUS;
    xfer(txbuf, rxbuf, 3);
    return rxbuf[2];
}

// SEND_IMAGE : 785 octets = commande + 784 pixels
static void send_image(const uint8_t *img)
{
    txbuf[0] = CMD_SEND_IMAGE;
    memcpy(txbuf + 1, img, 784);
    xfer(txbuf, NULL, 785);
}

// START_CONV : 1 octet
static void start_conv(void)
{
    txbuf[0] = CMD_START_CONV;
    xfer(txbuf, NULL, 1);
}

// READ_RESULT : 25 octets. MISO -> [ignore][24 logits]
//
// Le decodeur arme tx_byte des le decodage de la commande, donc le premier
// logit sort sur l'octet MISO 1 et non 2. Marge de course d'environ 80 ns
// entre l'armement (~417 ns apres le front) et le chargement de r_TX_Shift
// (500 ns). A revoir quand l'horloge systeme passera a 100 MHz : la latence
// tombera a ~50 ns et la marge deviendra confortable.
static void read_result(uint8_t *out24)
{
    memset(txbuf, 0, 28);
    txbuf[0] = CMD_READ_RESULT;
    xfer(txbuf, rxbuf, 25);
    memcpy(out24, rxbuf + 1, 24);
}

static void check(const char *name, int ok)
{
    if (ok)
    {
        pass++;
        ESP_LOGI(TAG, "  [OK]   %s", name);
    }
    else
    {
        fail++;
        ESP_LOGE(TAG, "  [FAIL] %s", name);
    }
}

static void wait_ready(void)
{
    int64_t t0 = esp_timer_get_time();
    while (gpio_get_level(PIN_READY) == 0)
    {
        if (esp_timer_get_time() - t0 > 1000000)
        { // garde-fou 1 s
            ESP_LOGW(TAG, "  timeout d'attente sur o_ready");
            return;
        }
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}

//=============================================================================
// Tests
//=============================================================================

// Le mock est au repos au demarrage : status 0x00 et o_ready a 1.
// Si o_ready lit 0 alors que busy vaut 0, c'est le fil ou la broche.
static void t1_repos(void)
{
    ESP_LOGI(TAG, "T1 — etat au repos");

    // Le FPGA n'est pas reinitialise quand l'ESP32 redemarre : done_latch
    // peut rester a 1 depuis la session precedente. Un READ_RESULT le purge.
    uint8_t purge[24];
    read_result(purge);
    vTaskDelay(pdMS_TO_TICKS(5));

    uint8_t s = get_status();
    int r = gpio_get_level(PIN_READY);

    if (s == 0xFF)
    {
        link_dead = 1;
        fail++;
        ESP_LOGE(TAG, "  [FAIL] MISO reste a 0xFF");
        ESP_LOGE(TAG, "  MISO est en haute impedance : CS_n n'atteint pas");
        ESP_LOGE(TAG, "  le FPGA. Verifier dans l'ordre :");
        ESP_LOGE(TAG, "   1. contact electrique des fils (pastilles soudees ?)");
        ESP_LOGE(TAG, "   2. fil CS_n : D3/GPIO4 -> JA4/L18");
        ESP_LOGE(TAG, "   3. masse commune JA5 <-> GND");
        ESP_LOGE(TAG, "   4. bitstream a jour sur la carte");
        return;
    }

    check("status = 0x00", s == 0x00);
    check("o_ready = 1", r == 1);
}

// Le mock recopie les 24 premiers octets recus dans result_buf.
// Ce test valide donc MOSI, le comptage des 784 octets et le chemin MISO.
static void t2_transfert(void)
{
    if (link_dead) return;
    ESP_LOGI(TAG, "T2 — SEND_IMAGE puis READ_RESULT");
    static uint8_t img[784];
    for (int i = 0; i < 784; i++)
        img[i] = (uint8_t)(i * 7 + 13);

    send_image(img);
    vTaskDelay(pdMS_TO_TICKS(5));

    uint8_t res[24];
    read_result(res);

    int bad = 0;
    for (int i = 0; i < 24; i++)
        if (res[i] != img[i])
            bad++;
    check("24 premiers octets identiques", bad == 0);

    if (bad)
    {
        ESP_LOGE(TAG, "  %d divergences. attendu[0]=0x%02X recu[0]=0x%02X",
                 bad, img[0], res[0]);
        ESP_LOGE(TAG, "  attendu[23]=0x%02X recu[23]=0x%02X",
                 img[23], res[23]);
        ESP_LOGW(TAG, "  Un decalage d'un rang indique result_buf synchrone");
        ESP_LOGW(TAG, "  au lieu de combinatoire.");
    }
}

// Le mock leve busy 208 ms. On verifie que le fil et le bit de statut
// basculent ensemble et que la duree est coherente.
static void t3_cycle_busy(void)
{
    if (link_dead) return;
    ESP_LOGI(TAG, "T3 — cycle busy");
    wait_ready();

    start_conv();
    vTaskDelay(pdMS_TO_TICKS(5));

    int r_pendant = gpio_get_level(PIN_READY);
    uint8_t s_pendant = get_status();

    int64_t t0 = esp_timer_get_time();
    wait_ready();
    int64_t duree = esp_timer_get_time() - t0;

    uint8_t s_apres = get_status();

    check("o_ready = 0 pendant busy", r_pendant == 0);
    check("bit busy leve", (s_pendant & 0x80) != 0);
    check("bit done leve apres", (s_apres & 0x40) != 0);
    check("duree entre 180 et 240 ms", duree > 180000 && duree < 240000);
    ESP_LOGI(TAG, "  duree mesuree : %lld us", duree);
}

// START_CONV doit effacer done_latch.
static void t4_start_efface_done(void)
{
    if (link_dead) return;
    ESP_LOGI(TAG, "T4 — START_CONV efface done");
    uint8_t s0 = get_status();
    check("done latche du test precedent", (s0 & 0x40) != 0);

    start_conv();
    vTaskDelay(pdMS_TO_TICKS(3));
    uint8_t s1 = get_status();
    check("done efface pendant le nouveau busy", (s1 & 0x40) == 0);

    wait_ready();
}

// Pendant busy, SEND_IMAGE doit etre ignore : l'image precedente reste.
static void t5_ignore_pendant_busy(void)
{
    if (link_dead) return;
    ESP_LOGI(TAG, "T5 — commandes ignorees pendant busy");
    static uint8_t marqueur[784];
    for (int i = 0; i < 784; i++)
        marqueur[i] = 0xAA;

    send_image(marqueur);
    start_conv();
    vTaskDelay(pdMS_TO_TICKS(20));

    static uint8_t intrus[784];
    for (int i = 0; i < 784; i++)
        intrus[i] = 0x55;
    send_image(intrus); // doit etre ignore

    wait_ready();

    uint8_t res[24];
    read_result(res);
    int alteres = 0;
    for (int i = 0; i < 24; i++)
        if (res[i] != 0xAA)
            alteres++;
    check("image intacte apres tentative pendant busy", alteres == 0);
}

// GET_STATUS reste accepte meme pendant busy.
static void t6_status_toujours_dispo(void)
{
    if (link_dead) return;
    ESP_LOGI(TAG, "T6 — GET_STATUS pendant busy");
    start_conv();
    vTaskDelay(pdMS_TO_TICKS(20));

    uint8_t s = get_status();
    check("reponse valide pendant busy", s != 0xFF);
    check("bit busy leve", (s & 0x80) != 0);

    wait_ready();
}

// La ligne o_ready doit toujours valoir l'inverse du bit busy.
static void t7_coherence(void)
{
    if (link_dead) return;
    ESP_LOGI(TAG, "T7 — coherence o_ready = !busy sur 20 lectures");
    int ok = 0;
    for (int i = 0; i < 20; i++)
    {
        uint8_t s = get_status();
        int r = gpio_get_level(PIN_READY);
        if (r == !((s >> 7) & 1))
            ok++;
        vTaskDelay(pdMS_TO_TICKS(30));
    }
    check("20 lectures coherentes", ok == 20);
}

//=============================================================================
void app_main(void)
{
    spi_init();
    ready_init();
    vTaskDelay(pdMS_TO_TICKS(500));

    ESP_LOGI(TAG, "=== Validation du lien SPI ESP32 <-> Cmod A7 ===");
    ESP_LOGI(TAG, "Bitstream attendu : top_mock");
    ESP_LOGI(TAG, "Firmware rev C — lecture a rxbuf+1, purge done_latch");

    t1_repos();
    t2_transfert();
    t3_cycle_busy();
    t4_start_efface_done();
    t5_ignore_pendant_busy();
    t6_status_toujours_dispo();
    t7_coherence();

    if (link_dead)
        ESP_LOGE(TAG, "=== Lien mort : tests suivants non executes ===");
    else
        ESP_LOGI(TAG, "=== %d OK, %d FAIL ===", pass, fail);
}