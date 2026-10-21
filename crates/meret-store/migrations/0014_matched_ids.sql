-- Where an ID came from: NULL for tags, else the lookup or match that gave it.
ALTER TABLE external_id ADD COLUMN provenance_id INTEGER REFERENCES provenance(id);
