import { Elysia } from "elysia";
import { staticPlugin } from "@elysiajs/static";
import { Database } from "bun:sqlite";
import "dotenv/config";

const PORT = 8090;
const SOCKET_KEY = process.env.SOCKET_KEY || "your-socket-key-here";
const GO2RTC_URL = process.env.GO2RTC_URL || "http://170.64.178.219:1984";
const SERVER_HOST = process.env.SERVER_HOST || "http://0.0.0.0:8090";

// Inisialisasi Database
const db = new Database("db/esp32cam.db");

// Buat tabel jika belum ada
const initSql = await Bun.file("db/init.sql").text();
db.exec(initSql);

// Prepared statements
const getDevice = db.prepare("SELECT * FROM devices WHERE serial_product = ?");
const insertDevice = db.prepare(`
  INSERT INTO devices (serial_product, first_connected, last_connected, stream_link)
  VALUES (?, ?, ?, ?)
`);
const updateDevice = db.prepare(`
  UPDATE devices 
  SET last_connected = ?, stream_link = ?
  WHERE serial_product = ?
`);
const deleteDevice = db.prepare("DELETE FROM devices WHERE serial_product = ?");
const getAllDevices = db.prepare(
  "SELECT * FROM devices ORDER BY last_connected DESC",
);

// Simpan frame terbaru per device
const latestFrames = new Map<
  string,
  {
    frame: Buffer;
    timestamp: number;
  }
>();

// Helper function untuk register stream ke go2rtc
async function registerStreamToGo2rtc(serialProduct: string) {
  try {
    const streamUrl1 = `${SERVER_HOST}/stream/${serialProduct}`;
    const streamUrl2 = `ffmpeg:${serialProduct}%23video=copy%23audio=none`;

    const url = `${GO2RTC_URL}/api/streams?name=${serialProduct}&src=${encodeURIComponent(streamUrl1)}&src=${encodeURIComponent(streamUrl2)}`;

    const response = await fetch(url, {
      method: "PUT",
    });

    if (response.ok) {
      console.log(`[go2rtc] Stream registered: ${serialProduct}`);
      return true;
    } else {
      console.error(
        `[go2rtc] Failed to register stream: ${serialProduct}`,
        await response.text(),
      );
      return false;
    }
  } catch (error) {
    console.error(`[go2rtc] Error registering stream:`, error);
    return false;
  }
}

// Helper function untuk delete stream dari go2rtc
async function deleteStreamFromGo2rtc(serialProduct: string) {
  try {
    const url = `${GO2RTC_URL}/api/streams?src=${serialProduct}`;

    const response = await fetch(url, {
      method: "DELETE",
    });

    if (response.ok) {
      console.log(`[go2rtc] Stream deleted: ${serialProduct}`);
      return true;
    } else {
      console.error(`[go2rtc] Failed to delete stream: ${serialProduct}`);
      return false;
    }
  } catch (error) {
    console.error(`[go2rtc] Error deleting stream:`, error);
    return false;
  }
}

const app = new Elysia()
  .use(
    staticPlugin({
      assets: "public",
      prefix: "/",
    }),
  )

  // WebSocket endpoint untuk menerima stream dari ESP32
  .ws("/push", {
    async open(ws) {
      const socketKey = ws.data.headers["socket-key"];
      const serialProduct = ws.data.headers["serial-product"];

      console.log(`[WS] Connection attempt - Serial: ${serialProduct}`);

      // Validasi SOCKET_KEY
      if (socketKey !== SOCKET_KEY) {
        console.log(`[WS] Rejected - Invalid socket key`);
        ws.close();
        return;
      }

      // Validasi SERIAL_PRODUCT
      if (!serialProduct) {
        console.log(`[WS] Rejected - Missing serial product`);
        ws.close();
        return;
      }

      ws.data.serialProduct = serialProduct;
      const now = new Date().toISOString();

      try {
        // Cek apakah device sudah terdaftar
        const device = getDevice.get(serialProduct);

        if (device) {
          // Update last_connected dan stream_link
          updateDevice.run(now, `/stream/${serialProduct}`, serialProduct);
          console.log(`[WS] Device reconnected: ${serialProduct}`);
        } else {
          // Insert device baru
          insertDevice.run(serialProduct, now, now, `/stream/${serialProduct}`);
          console.log(`[WS] New device registered: ${serialProduct}`);

          // Register ke go2rtc saat pertama kali terhubung
          await registerStreamToGo2rtc(serialProduct);
        }

        console.log(`[WS] Connected: ${serialProduct}`);
      } catch (error) {
        console.error("[WS] Database error:", error);
        ws.close();
      }
    },

    message(ws, message) {
      const serialProduct = ws.data.serialProduct;

      if (!serialProduct) return;

      // Simpan frame sebagai Buffer
      const frameBuffer =
        message instanceof ArrayBuffer
          ? Buffer.from(message)
          : Buffer.from(message as any);

      latestFrames.set(serialProduct, {
        frame: frameBuffer,
        timestamp: Date.now(),
      });

      console.log(
        `[${serialProduct}] Frame received: ${frameBuffer.length} bytes`,
      );
    },

    close(ws) {
      const serialProduct = ws.data.serialProduct;

      if (serialProduct) {
        try {
          // Set stream_link menjadi null saat disconnect
          updateDevice.run(new Date().toISOString(), null, serialProduct);
          console.log(`[WS] Disconnected: ${serialProduct}`);
        } catch (error) {
          console.error("[WS] Error on close:", error);
        }
      }
    },
  })

  // Endpoint untuk streaming video per device
  .get("/stream/:serial", ({ params: { serial }, set }) => {
    const frameData = latestFrames.get(serial);

    if (!frameData || !frameData.frame) {
      set.status = 404;
      return "No stream available for this device";
    }

    // Setup MJPEG stream
    set.headers = {
      "Content-Type": "multipart/x-mixed-replace; boundary=frame",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    };

    // Return stream generator
    return new ReadableStream({
      start(controller) {
        const interval = setInterval(() => {
          const data = latestFrames.get(serial);

          if (data && data.frame) {
            try {
              const boundary = "--frame\r\n";
              const contentType = "Content-Type: image/jpeg\r\n";
              const contentLength = `Content-Length: ${data.frame.length}\r\n\r\n`;
              const ending = "\r\n";

              controller.enqueue(new TextEncoder().encode(boundary));
              controller.enqueue(new TextEncoder().encode(contentType));
              controller.enqueue(new TextEncoder().encode(contentLength));
              controller.enqueue(data.frame);
              controller.enqueue(new TextEncoder().encode(ending));
            } catch (error) {
              clearInterval(interval);
              controller.close();
            }
          }
        }, 33); // ~30 FPS

        // Cleanup on close
        return () => {
          clearInterval(interval);
        };
      },
    });
  })

  // ========== go2rtc API Endpoints ==========

  // GET /api/streams - List semua stream
  .get("/api/streams", async ({ query }) => {
    try {
      // Jika ada parameter src, ambil detail stream tertentu
      if (query.src) {
        const response = await fetch(
          `${GO2RTC_URL}/api/streams?src=${query.src}`,
        );
        const streamData = await response.json();

        // Ambil data dari SQLite berdasarkan serial_product
        const device = getDevice.get(query.src as string);

        return {
          ...streamData,
          data: device || null,
        };
      }

      // Jika tidak ada parameter, list semua stream
      const response = await fetch(`${GO2RTC_URL}/api/streams`);
      const streams = await response.json();

      return streams;
    } catch (error) {
      return {
        success: false,
        error: (error as Error).message,
      };
    }
  })

  // PUT /api/streams - Create/Update stream
  .put("/api/streams", async ({ query }) => {
    try {
      const { name, src } = query;

      if (!name) {
        return {
          success: false,
          error: "Parameter 'name' is required",
        };
      }

      // Build URL dengan multiple src jika ada
      let url = `${GO2RTC_URL}/api/streams?name=${name}`;

      if (Array.isArray(src)) {
        src.forEach((s) => {
          url += `&src=${encodeURIComponent(s)}`;
        });
      } else if (src) {
        url += `&src=${encodeURIComponent(src as string)}`;
      }

      const response = await fetch(url, {
        method: "PUT",
      });

      const result = await response.json();

      return {
        success: response.ok,
        data: result,
      };
    } catch (error) {
      return {
        success: false,
        error: (error as Error).message,
      };
    }
  })

  // PATCH /api/streams - Update existing stream
  .patch("/api/streams", async ({ query }) => {
    try {
      const { name, src } = query;

      if (!name || !src) {
        return {
          success: false,
          error: "Parameters 'name' and 'src' are required",
        };
      }

      const url = `${GO2RTC_URL}/api/streams?name=${name}&src=${encodeURIComponent(src as string)}`;

      const response = await fetch(url, {
        method: "PATCH",
      });

      const result = await response.json();

      return {
        success: response.ok,
        data: result,
      };
    } catch (error) {
      return {
        success: false,
        error: (error as Error).message,
      };
    }
  })

  // DELETE /api/streams - Delete stream
  .delete("/api/streams", async ({ query }) => {
    try {
      const { src } = query;

      if (!src) {
        return {
          success: false,
          error: "Parameter 'src' is required",
        };
      }

      const serialProduct = src as string;

      // Delete dari go2rtc
      const go2rtcDeleted = await deleteStreamFromGo2rtc(serialProduct);

      // Delete dari SQLite
      let dbDeleted = false;
      try {
        deleteDevice.run(serialProduct);
        dbDeleted = true;
        console.log(`[DB] Device deleted: ${serialProduct}`);
      } catch (error) {
        console.error(`[DB] Error deleting device:`, error);
      }

      // Hapus dari latestFrames
      latestFrames.delete(serialProduct);

      return {
        success: go2rtcDeleted && dbDeleted,
        message: `Stream ${serialProduct} deleted from go2rtc and database`,
        go2rtc: go2rtcDeleted,
        database: dbDeleted,
      };
    } catch (error) {
      return {
        success: false,
        error: (error as Error).message,
      };
    }
  })

  // ========== Original API Endpoints ==========

  // API untuk mendapatkan semua devices (dari DB)
  .get("/api/devices", () => {
    try {
      const devices = getAllDevices.all();
      return {
        success: true,
        data: devices,
      };
    } catch (error) {
      return {
        success: false,
        error: (error as Error).message,
      };
    }
  })

  // API untuk status device
  .get("/api/status/:serial", ({ params: { serial } }) => {
    try {
      const device = getDevice.get(serial);
      const frameData = latestFrames.get(serial);

      if (!device) {
        return {
          success: false,
          error: "Device not found",
        };
      }

      return {
        success: true,
        data: {
          ...device,
          is_streaming: !!frameData,
          frame_age: frameData
            ? (Date.now() - frameData.timestamp) / 1000
            : null,
          frame_size: frameData?.frame.length || 0,
        },
      };
    } catch (error) {
      return {
        success: false,
        error: (error as Error).message,
      };
    }
  })
  .listen(PORT);

console.log("========================================");
console.log("ESP32-CAM Stream Server (ElysiaJS)");
console.log("========================================");
console.log(`Server running on: http://localhost:${PORT}`);
console.log(`WebSocket: ws://localhost:${PORT}/push`);
console.log(`Dashboard: http://localhost:${PORT}`);
console.log(`API Devices: http://localhost:${PORT}/api/devices`);
console.log(`go2rtc URL: ${GO2RTC_URL}`);
