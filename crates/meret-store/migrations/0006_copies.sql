-- Copies share a track and recording. The Rust migration merges existing
-- rows using the same title/position/length rules as the scanner.
ALTER TABLE source ADD COLUMN bitrate_kbps INTEGER;
