#!/bin/bash

# Script Setup VPS untuk menerima ESP-Cam Stream (Node.js Version)
# Author: Setup untuk go2rtc + Node.js Stream Receiver + Viseron
# Jalankan dengan: sudo bash setup_vps_nodejs.sh

set -e

echo "===== ESP-Cam VPS Setup Script (Node.js) ====="
echo "Menyiapkan environment untuk menerima stream dari ESP-Cam..."

# Update system
echo ">> Updating system..."
apt update && apt upgrade -y

# Install dependencies
echo ">> Installing dependencies..."
apt install -y curl wget git ffmpeg nginx ufw

# ===== 1. Setup Node.js =====
echo ">> Installing Node.js..."

if ! command -v node &> /dev/null; then
    # Install NodeSource repository untuk Node.js 20.x
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# Install PM2 untuk process management
if ! command -v pm2 &> /dev/null; then
    npm install -g pm2
    pm2 startup systemd -u root --hp /root
fi

echo "Node.js version: $(node --version)"
echo "NPM version: $(npm --version)"
echo "PM2 version: $(pm2 --version)"

# ===== 2. Setup Stream Receiver =====
echo ">> Setting up Stream Receiver (Node.js)..."

mkdir -p /opt/stream-receiver
cd /opt/stream-receiver

# Buat package.json
cat > package.json << 'EOF'
{
  "name": "esp-cam-stream-receiver",
  "version": "1.0.0",
  "description": "Node.js stream receiver for ESP32-CAM",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2"
  }
}
EOF

# Buat server.js
cat > server.js << 'EOF'
const express = require('express');
const app = express();
const PORT = 8090;

let latestFrame = null;
let lastFrameTime = 0;
let frameCount = 0;

app.use(express.raw({ 
  type: ['multipart/x-mixed-replace', 'image/jpeg', 'application/octet-stream'],
  limit: '10mb' 
}));

app.post('/push', (req, res) => {
  try {
    const contentType = req.get('Content-Type') || '';
    
    if (contentType.includes('multipart/x-mixed-replace')) {
      const boundary = contentType.split('boundary=')[1];
      
      if (boundary && req.body) {
        const boundaryBuffer = Buffer.from(`--${boundary}`);
        const data = req.body;
        const jpegMarker = Buffer.from('Content-Type: image/jpeg');
        const markerIndex = data.indexOf(jpegMarker);
        
        if (markerIndex !== -1) {
          const doubleCRLF = Buffer.from('\r\n\r\n');
          const dataStartIndex = data.indexOf(doubleCRLF, markerIndex);
          
          if (dataStartIndex !== -1) {
            const frameStart = dataStartIndex + 4;
            const nextBoundary = data.indexOf(boundaryBuffer, frameStart);
            const frameEnd = nextBoundary !== -1 ? nextBoundary : data.length;
            const frameData = data.slice(frameStart, frameEnd);
            
            let cleanFrame = frameData;
            while (cleanFrame.length > 0 && 
                   (cleanFrame[cleanFrame.length - 1] === 0x0A || 
                    cleanFrame[cleanFrame.length - 1] === 0x0D)) {
              cleanFrame = cleanFrame.slice(0, -1);
            }
            
            latestFrame = cleanFrame;
            lastFrameTime = Date.now();
            frameCount++;
            
            console.log(`[${new Date().toISOString()}] Frame: ${cleanFrame.length} bytes (Total: ${frameCount})`);
          }
        }
      }
    } else {
      latestFrame = req.body;
      lastFrameTime = Date.now();
      frameCount++;
      console.log(`[${new Date().toISOString()}] Frame: ${req.body.length} bytes (Total: ${frameCount})`);
    }
    
    res.status(200).send('OK');
  } catch (error) {
    console.error('Error:', error);
    res.status(500).send(error.message);
  }
});

app.get('/stream', (req, res) => {
  console.log(`[${new Date().toISOString()}] Stream client connected`);
  
  res.writeHead(200, {
    'Content-Type': 'multipart/x-mixed-replace; boundary=frame',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive'
  });
  
  const streamInterval = setInterval(() => {
    if (latestFrame && latestFrame.length > 0) {
      try {
        res.write('--frame\r\n');
        res.write('Content-Type: image/jpeg\r\n');
        res.write(`Content-Length: ${latestFrame.length}\r\n\r\n`);
        res.write(latestFrame);
        res.write('\r\n');
      } catch (error) {
        clearInterval(streamInterval);
      }
    }
  }, 33);
  
  req.on('close', () => {
    console.log(`[${new Date().toISOString()}] Stream client disconnected`);
    clearInterval(streamInterval);
  });
});

app.get('/status', (req, res) => {
  const now = Date.now();
  const frameAge = lastFrameTime > 0 ? (now - lastFrameTime) / 1000 : -1;
  
  res.json({
    status: latestFrame ? 'active' : 'waiting',
    last_frame_age: frameAge,
    frame_size: latestFrame ? latestFrame.length : 0,
    total_frames: frameCount,
    uptime: process.uptime()
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log('========================================');
  console.log('ESP-Cam Stream Receiver (Node.js)');
  console.log('========================================');
  console.log(`Server running on port ${PORT}`);
  console.log(`Stream: http://0.0.0.0:${PORT}/stream`);
  console.log(`Push:   http://0.0.0.0:${PORT}/push`);
  console.log(`Status: http://0.0.0.0:${PORT}/status`);
  console.log('========================================');
});

setInterval(() => {
  const frameAge = lastFrameTime > 0 ? (Date.now() - lastFrameTime) / 1000 : -1;
  const memUsage = process.memoryUsage();
  console.log(`[Monitor] Frames: ${frameCount} | Last: ${frameAge.toFixed(1)}s | Mem: ${(memUsage.heapUsed / 1024 / 1024).toFixed(2)} MB`);
}, 30000);
EOF

# Install dependencies
npm install

# Setup PM2
cat > ecosystem.config.js << 'EOF'
module.exports = {
  apps: [{
    name: 'esp-stream-receiver',
    script: './server.js',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '500M',
    env: {
      NODE_ENV: 'production',
      PORT: 8090
    }
  }]
};
EOF

# Start dengan PM2
pm2 start ecosystem.config.js
pm2 save

# ===== 3. Setup go2rtc =====
echo ">> Installing go2rtc..."

cd /opt
wget -q https://github.com/AlexxIT/go2rtc/releases/latest/download/go2rtc_linux_amd64
chmod +x go2rtc_linux_amd64
mv go2rtc_linux_amd64 go2rtc

mkdir -p /etc/go2rtc

cat > /etc/go2rtc/go2rtc.yaml << 'EOF'
api:
  listen: ":1984"

rtsp:
  listen: ":8554"

webrtc:
  listen: ":8555"

log:
  level: info
  format: text

streams:
EOF

cat > /etc/systemd/system/go2rtc.service << 'EOF'
[Unit]
Description=go2rtc service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/go2rtc -c /etc/go2rtc/go2rtc.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable go2rtc
systemctl start go2rtc

# ===== 4. Setup Docker untuk Viseron =====
echo ">> Installing Docker..."

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable docker
    systemctl start docker
    rm get-docker.sh
fi

if ! docker compose version &> /dev/null; then
    sudo apt update
    sudo apt install -y docker-compose-plugin
fi

# ===== 5. Setup Viseron =====
echo ">> Setting up Viseron..."

mkdir -p /opt/viseron/{config,recordings,models}
cd /opt/viseron

wget -q -O /opt/viseron/models/model.tflite \
  https://github.com/google-coral/test_data/raw/master/ssd_mobilenet_v2_coco_quant_postprocess_edgetpu.tflite

wget -q -O /opt/viseron/models/labels.txt \
  https://dl.google.com/coral/canned-models/coco_labels.txt

cat > /opt/viseron/docker-compose.yml << 'EOF'
version: "3.7"

services:
  viseron:
    image: roflcoopter/viseron:latest
    container_name: viseron
    volumes:
      - /opt/viseron/config:/config
      - /opt/viseron/recordings:/recordings
      - /opt/viseron/thumbnails:/thumbnails
      - /opt/viseron/snapshots:/snapshots
      - /opt/viseron/models:/models
      - /etc/localtime:/etc/localtime:ro
    environment:
      - TZ=Asia/Jakarta
    ports:
      - "8888:8888"
    restart: unless-stopped
    privileged: true
    network_mode: host
EOF

cat > /opt/viseron/config/config.yaml << 'EOF'
logger:
  default_level: info

cameras: {}

storage:
  tiers:
    - path: /recordings
      events:
        retain:
          days: 7
      recordings:
        retain:
          days: 7
      thumbnails:
        path: /thumbnails
      snapshots:
        path: /snapshots

recorder:
  esp_cam:
    lookback: 10
    timeout: 10
    retain: 7
    folder: /recordings/{camera_name}

motion_detector:
  fps: 1
  area: 0.08
  threshold: 25

webserver:
  port: 8888
  debug: false
EOF

docker-compose up -d

# ===== 6. Setup Firewall =====
echo ">> Configuring firewall..."

ufw --force enable
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 8090/tcp comment 'Stream Receiver'
ufw allow 1984/tcp comment 'go2rtc API'
ufw allow 8554/tcp comment 'RTSP'
ufw allow 8555/tcp comment 'WebRTC'
ufw allow 8888/tcp comment 'Viseron'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# ===== 7. Setup Nginx =====
echo ">> Setting up Nginx..."

cat > /etc/nginx/sites-available/esp-cam << 'EOF'
server {
    listen 80;
    server_name _;
    
    location /push {
        proxy_pass http://localhost:8090/push;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_request_buffering off;
        client_max_body_size 10M;
    }
    
    location /go2rtc/ {
        proxy_pass http://localhost:1984/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    location / {
        proxy_pass http://localhost:8888/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

ln -sf /etc/nginx/sites-available/esp-cam /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# ===== 8. Status Check =====
echo ""
echo "===== Installation Complete! ====="
echo ""
echo "Services Status:"
pm2 status
systemctl status go2rtc --no-pager | grep Active
docker ps | grep viseron

echo ""
echo "===== Access Information ====="
VPS_IP=$(curl -s ifconfig.me)
echo "VPS IP Address:  $VPS_IP"
echo ""
echo "Stream Receiver: http://$VPS_IP:8090/status"
echo "go2rtc Web UI:   http://$VPS_IP:1984"
echo "Viseron Web UI:  http://$VPS_IP:8888"
echo ""
echo "===== ESP-Cam Configuration ====="
echo "Update ESP-Cam Arduino code:"
echo "  vps_url = \"http://$VPS_IP:8090/push\""
echo ""
echo "===== Useful Commands ====="
echo "PM2 status:              pm2 status"
echo "PM2 logs:                pm2 logs esp-stream-receiver"
echo "PM2 restart:             pm2 restart esp-stream-receiver"
echo "Check stream:            curl http://localhost:8090/status"
echo "go2rtc logs:             journalctl -u go2rtc -f"
echo "Viseron logs:            docker logs -f viseron"
echo "Restart all:             pm2 restart all && systemctl restart go2rtc && docker restart viseron"
echo ""