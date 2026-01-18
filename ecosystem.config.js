module.exports = {
  apps: [
    {
      name: "esp-stream-receiver",
      script: "bun",
      args: "run index.ts",

      cwd: "/opt/stream-receiver",

      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: "500M",

      env: {
        NODE_ENV: "production",
        PORT: 8090
      },

      interpreter: "none"
    }
  ]
};