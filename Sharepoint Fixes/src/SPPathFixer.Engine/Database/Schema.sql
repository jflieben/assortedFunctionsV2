-- SPPathFixer database schema
-- Applied on first run via embedded resource

CREATE TABLE IF NOT EXISTS config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS scans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    status TEXT NOT NULL DEFAULT 'running',
    site_filter TEXT,
    extension_filter TEXT,
    max_path_length INTEGER NOT NULL DEFAULT 256,
    special_extensions TEXT,
    max_path_length_special INTEGER,
    total_sites INTEGER NOT NULL DEFAULT 0,
    total_libraries INTEGER NOT NULL DEFAULT 0,
    total_items_scanned INTEGER NOT NULL DEFAULT 0,
    total_long_paths INTEGER NOT NULL DEFAULT 0,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS long_path_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id INTEGER NOT NULL,
    site_url TEXT NOT NULL,
    library_title TEXT NOT NULL,
    library_server_relative_url TEXT NOT NULL,
    item_id TEXT NOT NULL,
    item_unique_id TEXT NOT NULL,
    item_name TEXT NOT NULL,
    item_extension TEXT NOT NULL DEFAULT '',
    item_type TEXT NOT NULL,
    file_ref TEXT NOT NULL,
    full_url TEXT NOT NULL,
    path_total_length INTEGER NOT NULL,
    path_parent_length INTEGER NOT NULL,
    path_leaf_length INTEGER NOT NULL,
    max_allowed INTEGER NOT NULL,
    delta INTEGER NOT NULL,
    deepest_child_depth INTEGER NOT NULL DEFAULT 0,
    fix_status TEXT NOT NULL DEFAULT 'pending',
    fix_strategy TEXT,
    fix_new_name TEXT,
    fix_result TEXT,
    fix_applied_at TEXT,
    FOREIGN KEY (scan_id) REFERENCES scans(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_lpi_scan_id ON long_path_items(scan_id);
CREATE INDEX IF NOT EXISTS idx_lpi_site_url ON long_path_items(site_url);
CREATE INDEX IF NOT EXISTS idx_lpi_item_type ON long_path_items(item_type);
CREATE INDEX IF NOT EXISTS idx_lpi_delta ON long_path_items(delta);
CREATE INDEX IF NOT EXISTS idx_lpi_fix_status ON long_path_items(fix_status);
CREATE INDEX IF NOT EXISTS idx_lpi_full_url ON long_path_items(full_url);

CREATE TABLE IF NOT EXISTS scan_progress (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id INTEGER NOT NULL,
    timestamp TEXT NOT NULL DEFAULT (datetime('now')),
    message TEXT NOT NULL,
    level TEXT NOT NULL DEFAULT 'info',
    FOREIGN KEY (scan_id) REFERENCES scans(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS fix_batches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id INTEGER NOT NULL,
    strategy TEXT NOT NULL,
    started_at TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    status TEXT NOT NULL DEFAULT 'running',
    total_items INTEGER NOT NULL DEFAULT 0,
    fixed_items INTEGER NOT NULL DEFAULT 0,
    failed_items INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (scan_id) REFERENCES scans(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (datetime('now')),
    action TEXT NOT NULL,
    details TEXT
);
