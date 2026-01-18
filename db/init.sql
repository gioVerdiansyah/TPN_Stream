CREATE TABLE IF NOT EXISTS devices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  serial_product TEXT UNIQUE NOT NULL,
  first_connected TEXT NOT NULL,
  last_connected TEXT NOT NULL,
  stream_link TEXT
);