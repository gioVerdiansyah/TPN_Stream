# Panduan Lengkap ESP32-CAM Streaming ke VPS dengan WebSocket dan MJPEG

## Gambaran Umum Sistem

Sistem ini memungkinkan Anda melakukan streaming video dari ESP32-CAM ke VPS menggunakan arsitektur berikut:

1. **ESP32-CAM** → Menangkap gambar dan mengirim via WebSocket
2. **Node.js Server (VPS)** → Menerima frame dari ESP32 dan menyediakan MJPEG stream
3. **Go2RTC** → Mengkonversi MJPEG stream menjadi format RTSP/WebRTC yang lebih fleksibel

```
[ESP32-CAM] --WebSocket--> [VPS:8080] --MJPEG:8090--> [Go2RTC] --RTSP/WebRTC--> Viseron
```

---

## 1. Konfigurasi ESP32-CAM

### Penjelasan Kode

Kode ESP32-CAM menggunakan library `ArduinoWebsockets` untuk mengirimkan frame kamera secara real-time ke server VPS.

### Kode Lengkap

```cpp
#include "esp_camera.h"
#include <WiFi.h>
#include <ArduinoWebsockets.h>

using namespace websockets;

// =====================
// KONFIGURASI WIFI & VPS
// =====================
const char* ssid = "FCB";
const char* password = "cetakfoto";

// Ganti dengan IP Public VPS Anda
const char* websockets_server_host = "170.64.178.219"; 
const uint16_t websockets_server_port = 8080; 

WebsocketsClient client;

// =====================
// KONFIGURASI KAMERA (AI Thinker)
// =====================
#define CAMERA_MODEL_AI_THINKER
#define PWDN_GPIO_NUM     32
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM      0
#define SIOD_GPIO_NUM     26
#define SIOC_GPIO_NUM     27
#define Y9_GPIO_NUM       35
#define Y8_GPIO_NUM       34
#define Y7_GPIO_NUM       39
#define Y6_GPIO_NUM       36
#define Y5_GPIO_NUM       21
#define Y4_GPIO_NUM       19
#define Y3_GPIO_NUM       18
#define Y2_GPIO_NUM        5
#define VSYNC_GPIO_NUM    25
#define HREF_GPIO_NUM     23
#define PCLK_GPIO_NUM     22

void setupCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  
  // -- PENTING: Setting Kualitas --
  // VGA (640x480) cukup stabil untuk streaming.
  // Jika putus-putus, turunkan ke HVGA atau QVGA.
  config.frame_size = FRAMESIZE_VGA; 
  config.jpeg_quality = 12; // 10-15 bagus. Makin kecil angka, makin bagus tapi file besar.
  config.fb_count = 2;

  if (esp_camera_init(&config) != ESP_OK) {
    Serial.println("Camera init failed");
    return;
  }
}

void connectWiFi() {
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWiFi Connected");
}

void setup() {
  Serial.begin(115200);
  connectWiFi();
  setupCamera();

  // Koneksi ke VPS via WebSocket
  Serial.println("Connecting to VPS...");
  bool connected = client.connect(websockets_server_host, websockets_server_port, "/");
  
  if(connected) {
      Serial.println("Connected to VPS!");
  } else {
      Serial.println("Connection failed!");
  }
}

void loop() {
  // Pastikan Client terkoneksi
  if(client.available()) {
    client.poll();
    
    // Ambil Frame Gambar
    camera_fb_t * fb = esp_camera_fb_get();
    if(!fb) {
      Serial.println("Camera capture failed");
      return;
    }

    // Kirim Binary Gambar lewat WebSocket
    client.sendBinary((const char *)fb->buf, fb->len);
    
    // Lepaskan memori frame
    esp_camera_fb_return(fb);
    
    // Delay sedikit untuk mengontrol Frame Rate (opsional)
    // Jangan terlalu cepat agar buffer VPS tidak membludak
    // delay(20); 
  } else {
    // Reconnect logic sederhana jika putus
    Serial.println("Disconnected... Reconnecting");
    client.connect(websockets_server_host, websockets_server_port, "/");
    delay(1000);
  }
}
```

### Poin-Poin Penting

**Konfigurasi Kualitas:**
- `FRAMESIZE_VGA` (640x480) - Resolusi standar yang stabil
- Alternatif: `FRAMESIZE_QVGA` (320x240) jika koneksi lambat
- `jpeg_quality = 12` - Nilai 10-15 optimal (semakin kecil = kualitas tinggi tapi ukuran besar)

**Frame Buffer:**
- `fb_count = 2` - Menggunakan double buffering untuk streaming lebih smooth

**Auto-Reconnect:**
- Loop utama akan otomatis mencoba koneksi ulang jika terputus

---

## 2. Setup Server MJPEG di VPS (Node.js)

### Instalasi Dependencies

```bash
npm init -y
npm install ws
```

### Kode Server (`server.js`)

```javascript
const http = require('http');
const WebSocket = require('ws');

let clients = [];
let lastFrame = null;

const server = http.createServer((req, res) => {
  if (req.url === '/stream') {
    res.writeHead(200, {
      'Content-Type': 'multipart/x-mixed-replace; boundary=frame',
      'Cache-Control': 'no-cache',
      'Connection': 'close'
    });

    clients.push(res);

    req.on('close', () => {
      clients = clients.filter(c => c !== res);
    });
  }
});

server.listen(8090);

const wss = new WebSocket.Server({ port: 8080 });
console.log('WS 8080, MJPEG 8090');

wss.on('connection', ws => {
  ws.on('message', frame => {
    lastFrame = frame;
    for (const res of clients) {
      res.write(`--frame\r\n`);
      res.write(`Content-Type: image/jpeg\r\n`);
      res.write(`Content-Length: ${frame.length}\r\n\r\n`);
      res.write(frame);
      res.write('\r\n');
    }
  });
});
```

### Cara Kerja Server

1. **WebSocket Server (Port 8080):**
   - Menerima koneksi dari ESP32-CAM
   - Menerima binary frame (JPEG) dari ESP32
   - Menyimpan frame terakhir di memori

2. **HTTP Server (Port 8090):**
   - Menyediakan endpoint `/stream` untuk MJPEG
   - Menggunakan format `multipart/x-mixed-replace` untuk streaming kontinyu
   - Setiap frame dikirim dengan boundary `--frame`

3. **Broadcasting:**
   - Setiap frame yang diterima dari ESP32 langsung di-broadcast ke semua client HTTP yang terhubung

---

## 3. Setup Go2RTC untuk Konversi Stream

### Download dan Setup

```bash
# Download binary
wget https://github.com/AlexxIT/go2rtc/releases/latest/download/go2rtc_linux_amd64

# Beri permission execute
chmod +x go2rtc_linux_amd64
```

### Buat file `go2rtc.yaml`

```yaml
streams:
  esp32:
    - "http://127.0.0.1:8090/stream"
```

### Penjelasan Konfigurasi

- **streams:** Daftar sumber streaming yang tersedia
- **esp32:** Nama stream (bisa disesuaikan)
- **URL:** Mengambil MJPEG stream dari server Node.js lokal

**Anda bisa menambahkan multiple streams:**

```yaml
streams:
  esp32_cam1:
    - "http://127.0.0.1:8090/stream"
  esp32_cam2:
    - "http://127.0.0.1:8091/stream"
  esp32_cam3:
    - "http://127.0.0.1:8092/stream"
```
Sesuaikan dengan setiap port ws

---

## 4. Menjalankan Sistem

### Langkah-langkah Startup

**Di VPS:**

```bash
# 1. Jalankan Node.js Server
node server.js

# 2. Jalankan Go2RTC (terminal baru)
./go2rtc_linux_amd64 -config go2rtc.yaml
```

**Di ESP32-CAM:**

1. Upload kode ke ESP32-CAM menggunakan Arduino IDE
2. Buka Serial Monitor untuk melihat status koneksi
3. ESP32 akan otomatis connect ke VPS

### Mengakses Stream

Setelah semua berjalan, Anda bisa akses stream melalui:

- **MJPEG Direct:** `http://VPS_IP:8090/stream`
- **Go2RTC Web UI:** `http://VPS_IP:1984/` (default port Go2RTC)
- **RTSP URL:** `rtsp://VPS_IP:8554/esp32`
- **WebRTC:** Melalui Go2RTC web interface

---

## 5. Troubleshooting

### ESP32 Tidak Terkoneksi

- Pastikan IP VPS benar dan bisa diakses
- Cek firewall VPS, port 8080 harus terbuka
- Periksa kredensial WiFi

### Stream Putus-Putus

- Turunkan resolusi ke `FRAMESIZE_QVGA`
- Tingkatkan `jpeg_quality` ke 15-20
- Tambahkan `delay(20)` di loop ESP32
- Periksa bandwidth jaringan

### Kualitas Gambar Buruk

- Turunkan nilai `jpeg_quality` (10-12)
- Tingkatkan resolusi ke `FRAMESIZE_SVGA`
- Pastikan pencahayaan memadai

### Go2RTC Tidak Mendeteksi Stream

- Pastikan server Node.js sudah berjalan
- Test MJPEG stream di browser: `http://localhost:8090/stream`
- Periksa syntax file `go2rtc.yaml`

---

## 6. Optimasi Lanjutan

### Meningkatkan FPS

```cpp
// Di loop(), hapus atau kurangi delay
// delay(20); // Hapus atau kurangi jadi delay(10)
```

### Menambahkan Authentication

Tambahkan token sederhana di ESP32 dan validasi di server:

```javascript
wss.on('connection', (ws, req) => {
  const token = new URL(req.url, 'http://localhost').searchParams.get('token');
  if (token !== 'SECRET_TOKEN') {
    ws.close();
    return;
  }
  // ... rest of code
});
```

### Menggunakan PM2 untuk Auto-Restart

```bash
npm install -g pm2
pm2 start server.js --name esp32-streaming
pm2 startup
pm2 save
```

---

## Kesimpulan

Sistem ini memberikan solusi streaming yang robust dengan beberapa keuntungan:

- **Low Latency:** WebSocket memberikan latency rendah
- **Scalable:** Bisa menambahkan multiple ESP32-CAM
- **Fleksibel:** Go2RTC support berbagai protokol (RTSP, WebRTC, HLS)
- **Mudah Diintegrasikan:** Bisa digunakan dengan Home Assistant, Frigate, dll

Selamat mencoba!