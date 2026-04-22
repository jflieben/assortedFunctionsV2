/* SPPathFixer — Vanilla JS SPA */
/* Hash-based routing, no build step, no frameworks */

(function () {
    'use strict';

    // ── API Helper ──────────────────────────────────────────────
    const api = {
        async get(url) {
            const res = await fetch(`/api${url}`);
            return res.json();
        },
        async post(url, body) {
            const res = await fetch(`/api${url}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: body ? JSON.stringify(body) : undefined
            });
            return res.json();
        },
        async put(url, body) {
            const res = await fetch(`/api${url}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            return res.json();
        },
        async del(url) {
            const res = await fetch(`/api${url}`, { method: 'DELETE' });
            return res.json();
        },
        async getBlob(url) {
            return fetch(`/api${url}`);
        }
    };

    // ── Toast ───────────────────────────────────────────────────
    function showToast(message, type = 'info') {
        const c = document.getElementById('toast-container');
        const t = document.createElement('div');
        t.className = `toast ${type}`;
        t.textContent = message;
        c.appendChild(t);
        setTimeout(() => t.remove(), 4000);
    }

    // ── Theme ───────────────────────────────────────────────────
    function initTheme() {
        const saved = localStorage.getItem('spfix-theme') || 'dark';
        document.documentElement.setAttribute('data-theme', saved);
        updateThemeIcon(saved);
        document.getElementById('themeToggle').addEventListener('click', () => {
            const cur = document.documentElement.getAttribute('data-theme');
            const next = cur === 'dark' ? 'light' : 'dark';
            document.documentElement.setAttribute('data-theme', next);
            localStorage.setItem('spfix-theme', next);
            updateThemeIcon(next);
        });
    }
    function updateThemeIcon(theme) {
        document.getElementById('themeToggle').textContent = theme === 'dark' ? '☀️' : '🌙';
    }

    // ── State ───────────────────────────────────────────────────
    let state = {
        connected: false,
        tenantDomain: '',
        userPrincipalName: '',
        authMode: '',
        moduleVersion: '',
        scanning: false,
        activeScanId: null,
        fixing: false,
        activeFixBatchId: null
    };

    let pollTimer = null;

    // ── Status Polling ──────────────────────────────────────────
    async function refreshStatus() {
        try {
            const res = await api.get('/status');
            if (res.success) {
                Object.assign(state, res.data);
                updateNavStatus();
            }
        } catch { /* ignore */ }
    }

    function updateNavStatus() {
        const badge = document.getElementById('connectionStatus');
        const ver = document.getElementById('navVersion');
        if (state.moduleVersion) ver.textContent = `v${state.moduleVersion}`;

        if (state.fixing) {
            badge.textContent = 'Fixing...';
            badge.className = 'status-badge fixing';
        } else if (state.scanning) {
            badge.textContent = 'Scanning...';
            badge.className = 'status-badge scanning';
        } else if (state.connected) {
            badge.textContent = state.tenantDomain || 'Connected';
            badge.className = 'status-badge connected';
        } else {
            badge.textContent = 'Disconnected';
            badge.className = 'status-badge disconnected';
        }
    }

    // ── Router ──────────────────────────────────────────────────
    const routes = {
        '/': renderDashboard,
        '/scan': renderScan,
        '/results': renderResults,
        '/fix': renderFix,
        '/settings': renderSettings
    };

    function navigate() {
        const hash = window.location.hash.slice(1) || '/';
        const path = hash.split('?')[0];
        const render = routes[path] || renderDashboard;
        document.querySelectorAll('.nav-link').forEach(link => {
            const page = link.getAttribute('data-page');
            link.classList.toggle('active', path === '/' ? page === 'dashboard' : path === `/${page}`);
        });
        render();
    }

    // ── Helpers ─────────────────────────────────────────────────
    function $(sel) { return document.querySelector(sel); }
    function h(tag, attrs, ...children) {
        const el = document.createElement(tag);
        if (attrs) Object.entries(attrs).forEach(([k, v]) => {
            if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
            else if (k === 'className') el.className = v;
            else if (k === 'innerHTML') el.innerHTML = v;
            else el.setAttribute(k, v);
        });
        children.flat().forEach(c => {
            if (typeof c === 'string') el.appendChild(document.createTextNode(c));
            else if (c) el.appendChild(c);
        });
        return el;
    }

    function formatNumber(n) {
        return (n || 0).toLocaleString();
    }

    function formatDuration(totalSeconds) {
        const seconds = Math.max(0, parseInt(totalSeconds || 0, 10));
        const h = Math.floor(seconds / 3600);
        const m = Math.floor((seconds % 3600) / 60);
        const s = seconds % 60;
        if (h > 0) return `${h}h ${m}m ${s}s`;
        if (m > 0) return `${m}m ${s}s`;
        return `${s}s`;
    }

    function siteRelativePath(url) {
        if (!url) return '';
        try { return new URL(url).pathname || url; } catch { return url; }
    }

    function pathLengthBadge(len, max) {
        const delta = len - max;
        if (delta > 50) return `<span class="badge badge-critical">${len} (+${delta})</span>`;
        if (delta > 20) return `<span class="badge badge-warning">${len} (+${delta})</span>`;
        return `<span class="badge badge-info">${len} (+${delta})</span>`;
    }

    // ═══════════════════════════════════════════════════════════
    // ── Dashboard Page ─────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    async function renderDashboard() {
        const app = $('#app');
        app.innerHTML = '<h2>Dashboard</h2>';

        if (!state.connected) {
            app.innerHTML += `
                <div class="card" style="margin-top:16px">
                    <div class="empty-state">
                        <div class="emoji">🔌</div>
                        <h3>Not Connected</h3>
                        <p>Connect to SharePoint Online to start scanning for long paths.</p>
                        <div style="margin-top:16px">
                            <h4>Delegated (Interactive)</h4>
                            <p style="color:var(--text-muted);font-size:0.85em;margin:8px 0">Sign in with your browser. Best for ad-hoc scans but requires you have access to each site.</p>
                            <button class="btn btn-primary" id="btnConnectDelegated">Connect with Browser</button>
                        </div>
                        <div style="margin-top:24px;padding-top:16px;border-top:1px solid var(--border)">
                            <h4>Certificate (App-Only)</h4>
                            <p style="color:var(--text-muted);font-size:0.85em;margin:8px 0">Use a certificate for unattended scans. Requires an app registration with Sites.ReadWrite.All.</p>
                            <div class="form-row" style="text-align:left;max-width:500px;margin:12px auto">
                                <div class="form-group"><label>Client ID</label><input id="certClientId" placeholder="App registration client ID"></div>
                                <div class="form-group"><label>Tenant ID</label><input id="certTenantId" placeholder="Tenant ID or domain"></div>
                            </div>
                            <div class="form-row" style="text-align:left;max-width:500px;margin:0 auto">
                                <div class="form-group"><label>PFX Path</label><input id="certPfxPath" placeholder="C:\\certs\\app.pfx"></div>
                                <div class="form-group"><label>PFX Password</label><input id="certPfxPass" type="password" placeholder="Certificate password"></div>
                            </div>
                            <p style="color:var(--text-muted);font-size:0.8em;margin:4px 0">Or use a thumbprint from the local certificate store instead of a PFX file:</p>
                            <div style="max-width:500px;margin:0 auto"><div class="form-group"><label>Thumbprint</label><input id="certThumbprint" placeholder="Certificate thumbprint (optional)"></div></div>
                            <button class="btn btn-secondary" id="btnConnectCert" style="margin-top:8px">Connect with Certificate</button>
                        </div>
                    </div>
                </div>`;

            document.getElementById('btnConnectDelegated').onclick = async () => {
                try {
                    const res = await api.post('/connect', { mode: 'delegated' });
                    if (res.success) { showToast('Connected!', 'success'); await refreshStatus(); navigate(); }
                    else showToast(res.error || 'Connection failed', 'error');
                } catch (e) { showToast('Connection failed: ' + e.message, 'error'); }
            };

            document.getElementById('btnConnectCert').onclick = async () => {
                const body = {
                    mode: 'certificate',
                    clientId: document.getElementById('certClientId').value,
                    tenantId: document.getElementById('certTenantId').value,
                    pfxPath: document.getElementById('certPfxPath').value,
                    pfxPassword: document.getElementById('certPfxPass').value,
                    thumbprint: document.getElementById('certThumbprint').value
                };
                if (!body.clientId || !body.tenantId) { showToast('Client ID and Tenant ID are required', 'warning'); return; }
                try {
                    const res = await api.post('/connect', body);
                    if (res.success) { showToast('Connected via certificate!', 'success'); await refreshStatus(); navigate(); }
                    else showToast(res.error || 'Connection failed', 'error');
                } catch (e) { showToast('Connection failed: ' + e.message, 'error'); }
            };
            return;
        }

        // Connected — show summary
        app.innerHTML += `
            <div class="stat-grid" id="dashStats"></div>
            <div class="card">
                <div class="card-header">
                    <h3>Recent Scans</h3>
                    <button class="btn btn-primary" onclick="location.hash='#/scan'">New Scan</button>
                </div>
                <div id="recentScans"></div>
            </div>
            <div class="card">
                <div class="card-header"><h3>Permissions Check</h3></div>
                <div id="permCheck"><button class="btn btn-secondary" id="btnPermCheck">Check Permissions</button></div>
            </div>
            <div class="card">
                <div class="card-header">
                    <h3>Connection</h3>
                    <button class="btn btn-danger" id="btnDashDisconnect">Disconnect / Switch Auth</button>
                </div>
                <p style="color:var(--text-muted);font-size:0.9em">Connected to <strong>${state.tenantDomain || 'unknown'}</strong> as <strong>${state.userPrincipalName || 'app'}</strong> (${state.authMode || 'unknown'})</p>
                ${state.authMode === 'Delegated' ? '<p style="color:var(--warning);font-size:0.85em;margin-top:8px">⚠️ Delegated auth: you can only scan sites where you are a member or owner. If sites are missing, ask a SharePoint admin to grant you access or use certificate (app-only) auth instead.</p>' : ''}
            </div>`;

        document.getElementById('btnDashDisconnect').onclick = async () => {
            await api.post('/disconnect');
            await refreshStatus();
            showToast('Disconnected. You can now reconnect with a different auth mode.', 'info');
            navigate();
        };

        // Load scans
        try {
            const res = await api.get('/scans');
            if (res.success && res.data && res.data.length > 0) {
                const scans = res.data.slice(0, 5);
                let totalItems = 0;
                const summaries = [];
                for (const scan of scans) {
                    try {
                        const s = await api.get(`/scans/${scan.id}/summary`);
                        if (s.success) { totalItems += s.data.totalItems; summaries.push({ scan, summary: s.data }); }
                        else summaries.push({ scan, summary: null });
                    } catch { summaries.push({ scan, summary: null }); }
                }

                document.getElementById('dashStats').innerHTML = `
                    <div class="stat-card"><div class="stat-value">${res.data.length}</div><div class="stat-label">Total Scans</div></div>
                    <div class="stat-card"><div class="stat-value">${formatNumber(totalItems)}</div><div class="stat-label">Long Path Items</div></div>
                    <div class="stat-card"><div class="stat-value">${state.tenantDomain}</div><div class="stat-label">Tenant</div></div>
                    <div class="stat-card"><div class="stat-value">${state.authMode || 'delegated'}</div><div class="stat-label">Auth Mode</div></div>`;

                let tableHtml = `<div class="table-wrapper"><table>
                    <tr><th>ID</th><th>Started</th><th>Status</th><th>Sites</th><th>Items Found</th><th>Actions</th></tr>`;
                for (const { scan, summary } of summaries) {
                    tableHtml += `<tr>
                        <td>${scan.id}</td>
                        <td>${new Date(scan.startedAt).toLocaleString()}</td>
                        <td>${scan.status}</td>
                        <td>${scan.totalSites || '-'}</td>
                        <td>${summary ? formatNumber(summary.totalItems) : '-'}</td>
                        <td><button class="btn btn-secondary" onclick="location.hash='#/results?scanId=${scan.id}'">View</button></td>
                    </tr>`;
                }
                tableHtml += '</table></div>';
                document.getElementById('recentScans').innerHTML = tableHtml;
            } else {
                document.getElementById('dashStats').innerHTML = `
                    <div class="stat-card"><div class="stat-value">${state.tenantDomain}</div><div class="stat-label">Tenant</div></div>
                    <div class="stat-card"><div class="stat-value">${state.authMode || 'delegated'}</div><div class="stat-label">Auth Mode</div></div>`;
                document.getElementById('recentScans').innerHTML = '<div class="empty-state"><div class="emoji">📂</div><p>No scans yet. Start a new scan to find long paths.</p></div>';
            }
        } catch { document.getElementById('recentScans').innerHTML = '<p>Failed to load scans.</p>'; }

        // Permission check button
        document.getElementById('btnPermCheck').onclick = async () => {
            document.getElementById('permCheck').innerHTML = '<p style="color:var(--text-muted)">Checking permissions...</p>';
            try {
                const res = await api.get('/permissions/check');
                if (res.success) {
                    const d = res.data;
                    let html = `<p style="margin-bottom:12px">Auth mode: <strong>${d.authMode}</strong></p>`;
                    if (d.hasRequiredPermissions) {
                        html += '<p style="color:var(--success)">✅ All required permissions are present.</p>';
                    } else {
                        html += '<p style="color:var(--error)">❌ Missing required permissions:</p><ul>';
                        (d.missingPermissions || []).forEach(p => html += `<li>${p}</li>`);
                        html += '</ul>';
                        if (d.guidance) html += `<p style="margin-top:12px;color:var(--text-muted)">${d.guidance}</p>`;
                    }
                    document.getElementById('permCheck').innerHTML = html;
                } else {
                    document.getElementById('permCheck').innerHTML = `<p style="color:var(--error)">${res.error}</p>`;
                }
            } catch (e) { document.getElementById('permCheck').innerHTML = `<p style="color:var(--error)">Error: ${e.message}</p>`; }
        };
    }

    // ═══════════════════════════════════════════════════════════
    // ── Scan Page ──────────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    let scanPollTimer = null;
    let sitePickerState = null;

    async function renderScan() {
        const app = $('#app');

        if (state.scanning) {
            app.innerHTML = `
                <h2>Scan in Progress</h2>
                <div class="card" id="scanProgressCard">
                    <div id="scanProgressContent">Loading...</div>
                    <div style="margin-top:16px"><button class="btn btn-danger" id="btnCancelScan">Cancel Scan</button></div>
                </div>
                <div class="card"><h3>Log</h3><div class="log-area" id="scanLog"></div></div>`;

            document.getElementById('btnCancelScan').onclick = async () => {
                await api.post('/scan/cancel');
                showToast('Scan cancelled', 'warning');
            };

            pollScanProgress();
            return;
        }

        app.innerHTML = `
            <h2>Start New Scan</h2>
            <div class="card">
                <h3>Scan Scope</h3>
                <div class="form-group">
                    <label><input type="radio" name="scopeType" value="all" checked style="width:auto"> All sites in tenant</label>
                </div>
                <div class="form-group">
                    <label><input type="radio" name="scopeType" value="select" style="width:auto"> Select specific sites</label>
                </div>
                <div id="siteSelector" style="display:none;margin-top:12px">
                    <div class="form-row" style="align-items:flex-end">
                        <div class="form-group" style="min-width:280px;flex:2">
                            <label>Search Sites</label>
                            <input id="siteSearchInput" placeholder="Search by title or URL (server-side)">
                        </div>
                        <div class="form-group" style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
                            <button class="btn btn-secondary" id="btnLoadSites">Load Sites</button>
                            <button class="btn btn-secondary" id="btnLoadMoreSites" disabled>Load More</button>
                        </div>
                    </div>
                    <div class="form-group" style="display:flex;gap:8px;flex-wrap:wrap">
                        <button class="btn btn-secondary" id="btnSelectVisibleSites">Select Visible</button>
                        <button class="btn btn-secondary" id="btnClearVisibleSites">Clear Visible</button>
                        <button class="btn btn-secondary" id="btnClearSelectedSites">Clear All Selected</button>
                    </div>
                    <p id="siteSelectionSummary" style="color:var(--text-muted);font-size:0.85em;margin:8px 0">No sites loaded yet.</p>
                    <div id="siteList" style="margin-top:8px"></div>
                    <div class="form-group" style="margin-top:12px">
                        <label>Manual Site URLs (optional)</label>
                        <textarea id="manualSiteUrls" rows="4" placeholder="https://tenant.sharepoint.com/sites/Finance&#10;https://tenant.sharepoint.com/sites/HR"></textarea>
                        <span style="font-size:0.8em;color:var(--text-muted)">Add one URL per line (or comma-separated) to target specific sites directly.</span>
                    </div>
                </div>
            </div>
            <div class="card">
                <h3>Scan Options</h3>
                <div class="form-row">
                    <div class="form-group">
                        <label>Max Path Length</label>
                        <input type="number" id="scanMaxPath" value="400" min="100" max="1000">
                        <span style="font-size:0.8em;color:var(--text-muted)">Characters. SharePoint limit is ~400.</span>
                    </div>
                    <div class="form-group">
                        <label>Extension Filter</label>
                        <input id="scanExtFilter" placeholder=".xlsx,.docx (empty = all files)">
                    </div>
                </div>
            </div>
            <button class="btn btn-primary" id="btnStartScan" style="margin-top:8px">Start Scan</button>`;

        // Toggle site selection
        document.querySelectorAll('input[name="scopeType"]').forEach(r => {
            r.addEventListener('change', () => {
                document.getElementById('siteSelector').style.display = r.value === 'select' ? 'block' : 'none';
            });
        });

        resetSitePicker();

        // Load sites
        document.getElementById('btnLoadSites').onclick = async () => {
            await loadSitesPage({ reset: true });
        };

        document.getElementById('btnLoadMoreSites').onclick = async () => {
            await loadSitesPage({ reset: false });
        };

        document.getElementById('btnSelectVisibleSites').onclick = () => {
            if (!sitePickerState?.visibleItems?.length) return;
            sitePickerState.visibleItems.forEach(s => {
                if (s.webUrl) sitePickerState.selected.set(s.webUrl, s);
            });
            renderSiteList();
            updateSiteSelectionSummary();
        };

        document.getElementById('btnClearVisibleSites').onclick = () => {
            if (!sitePickerState?.visibleItems?.length) return;
            sitePickerState.visibleItems.forEach(s => {
                if (s.webUrl) sitePickerState.selected.delete(s.webUrl);
            });
            renderSiteList();
            updateSiteSelectionSummary();
        };

        document.getElementById('btnClearSelectedSites').onclick = () => {
            if (!sitePickerState) return;
            sitePickerState.selected.clear();
            renderSiteList();
            updateSiteSelectionSummary();
        };

        document.getElementById('siteSearchInput').addEventListener('keydown', async (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                await loadSitesPage({ reset: true });
            }
        });

        // Start scan
        document.getElementById('btnStartScan').onclick = async () => {
            const scopeType = document.querySelector('input[name="scopeType"]:checked').value;
            const body = {
                maxPathLength: parseInt(document.getElementById('scanMaxPath').value) || 400,
                extensionFilter: document.getElementById('scanExtFilter').value
            };

            if (scopeType === 'select') {
                body.siteUrls = collectSelectedSiteUrls();
                if (body.siteUrls.length === 0) { showToast('Select at least one site', 'warning'); return; }
            }

            try {
                const res = await api.post('/scan/start', body);
                if (res.success) {
                    showToast('Scan started!', 'success');
                    await refreshStatus();
                    navigate();
                } else {
                    showToast(res.error || 'Failed to start scan', 'error');
                }
            } catch (e) { showToast('Error: ' + e.message, 'error'); }
        };
    }

    function resetSitePicker() {
        sitePickerState = {
            query: '',
            nextCursor: null,
            hasMore: false,
            loadedCount: 0,
            selected: new Map(),
            itemsByUrl: new Map(),
            visibleItems: []
        };
        renderSiteList();
        updateSiteSelectionSummary();
        const btnLoadMore = document.getElementById('btnLoadMoreSites');
        if (btnLoadMore) btnLoadMore.disabled = true;
    }

    function renderSiteList() {
        const listEl = document.getElementById('siteList');
        if (!listEl || !sitePickerState) return;

        const items = Array.from(sitePickerState.itemsByUrl.values());
        sitePickerState.visibleItems = items;

        if (items.length === 0) {
            listEl.innerHTML = '<p style="color:var(--text-muted)">No sites loaded. Use search + Load Sites, or add URLs manually below.</p>';
            return;
        }

        let html = '<div class="site-list">';
        items.forEach((s, idx) => {
            const checked = sitePickerState.selected.has(s.webUrl) ? 'checked' : '';
            const label = s.displayName || s.webUrl;
            html += `<label class="site-item" title="${s.webUrl}"><input type="checkbox" data-site-url="${s.webUrl}" ${checked}> ${label}</label>`;
            if (idx < items.length - 1) html += '';
        });
        html += '</div>';
        listEl.innerHTML = html;

        listEl.querySelectorAll('input[type="checkbox"][data-site-url]').forEach(cb => {
            cb.addEventListener('change', () => {
                const url = cb.getAttribute('data-site-url');
                if (!url) return;
                const site = sitePickerState.itemsByUrl.get(url) || { webUrl: url, displayName: '' };
                if (cb.checked) sitePickerState.selected.set(url, site);
                else sitePickerState.selected.delete(url);
                updateSiteSelectionSummary();
            });
        });
    }

    function updateSiteSelectionSummary() {
        const el = document.getElementById('siteSelectionSummary');
        if (!el || !sitePickerState) return;
        const selectedCount = sitePickerState.selected.size;
        const loadedCount = sitePickerState.loadedCount;
        const more = sitePickerState.hasMore ? 'More available.' : 'End of results.';
        el.textContent = `Loaded: ${formatNumber(loadedCount)} site(s). Selected: ${formatNumber(selectedCount)}. ${more}`;
    }

    async function loadSitesPage({ reset }) {
        const listEl = document.getElementById('siteList');
        const btnLoad = document.getElementById('btnLoadSites');
        const btnLoadMore = document.getElementById('btnLoadMoreSites');
        const searchInput = document.getElementById('siteSearchInput');
        if (!listEl || !btnLoad || !btnLoadMore || !searchInput) return;

        if (!sitePickerState) resetSitePicker();

        if (reset) {
            const query = (searchInput.value || '').trim();
            sitePickerState.query = query;
            sitePickerState.nextCursor = null;
            sitePickerState.hasMore = false;
            sitePickerState.loadedCount = 0;
            sitePickerState.itemsByUrl = new Map();
            sitePickerState.visibleItems = [];
            listEl.innerHTML = '<p style="color:var(--text-muted)">Loading sites...</p>';
        } else {
            if (!sitePickerState.nextCursor) {
                showToast('No more sites to load', 'info');
                return;
            }
        }

        btnLoad.disabled = true;
        btnLoadMore.disabled = true;

        try {
            const params = new URLSearchParams();
            params.set('pageSize', '100');
            if (sitePickerState.query) params.set('query', sitePickerState.query);
            if (!reset && sitePickerState.nextCursor) params.set('cursor', sitePickerState.nextCursor);

            const res = await api.get(`/sites?${params.toString()}`);
            if (!res.success || !res.data) {
                listEl.innerHTML = `<p style="color:var(--error)">${res.error || 'Failed to load sites.'}</p>`;
                return;
            }

            const page = res.data;
            (page.items || []).forEach(s => {
                if (s?.webUrl && !sitePickerState.itemsByUrl.has(s.webUrl))
                    sitePickerState.itemsByUrl.set(s.webUrl, s);
            });

            sitePickerState.loadedCount = sitePickerState.itemsByUrl.size;
            sitePickerState.nextCursor = page.nextCursor || null;
            sitePickerState.hasMore = !!page.hasMore;

            renderSiteList();
            updateSiteSelectionSummary();
        } catch (e) {
            listEl.innerHTML = `<p style="color:var(--error)">${e.message}</p>`;
        } finally {
            btnLoad.disabled = false;
            btnLoadMore.disabled = !sitePickerState?.hasMore;
        }
    }

    function collectSelectedSiteUrls() {
        const selected = sitePickerState
            ? Array.from(sitePickerState.selected.keys())
            : [];

        const manual = (document.getElementById('manualSiteUrls')?.value || '')
            .split(/[\n,;]+/)
            .map(v => v.trim())
            .filter(v => !!v)
            .filter(v => /^https?:\/\//i.test(v));

        return Array.from(new Set([...selected, ...manual]));
    }

    async function pollScanProgress() {
        if (scanPollTimer) clearInterval(scanPollTimer);
        const update = async () => {
            try {
                const res = await api.get('/scan/progress');
                if (res.success) {
                    const p = res.data;
                    const pct = p.overallPercent || 0;
                    const phase = p.phase || 'running';
                    const libDone = p.processedLibraries || 0;
                    const libTotal = p.totalLibraries || 0;
                    const ips = p.itemsPerSecond || 0;
                    const elapsed = formatDuration(p.elapsedSeconds || 0);
                    const eta = (p.estimatedRemainingSeconds || 0) > 0
                        ? formatDuration(p.estimatedRemainingSeconds)
                        : '-';
                    document.getElementById('scanProgressContent').innerHTML = `
                        <p><strong>Status:</strong> ${p.status || 'scanning'} (${phase})</p>
                        <p><strong>Current:</strong> ${p.currentSite || '-'}${p.currentLibrary ? ' / ' + p.currentLibrary : ''}</p>
                        <div class="progress-bar"><div class="progress-fill" style="width:${pct}%"></div></div>
                        <p style="font-size:0.85em;color:var(--text-muted)">${pct}% — Sites: ${p.processedSites || 0}/${p.totalSites || '?'} — Libraries: ${libDone}/${libTotal || '?'} — Items scanned: ${formatNumber(p.totalItemsScanned || 0)} — Long paths: ${formatNumber(p.totalLongPaths || 0)}</p>
                        <p style="font-size:0.82em;color:var(--text-muted)">Speed: ${formatNumber(ips)} items/s — Elapsed: ${elapsed} — ETA: ${eta}</p>`;

                    if (p.recentLogs && p.recentLogs.length) {
                        const logArea = document.getElementById('scanLog');
                        logArea.innerHTML = p.recentLogs.map(l =>
                            `<div class="log-entry log-${l.level || 'info'}">[${l.timestamp ? new Date(l.timestamp).toLocaleTimeString() : ''}] ${l.message}</div>`
                        ).join('');
                        logArea.scrollTop = logArea.scrollHeight;
                    }

                    if (p.status === 'completed' || p.status === 'cancelled' || p.status === 'failed') {
                        clearInterval(scanPollTimer);
                        await refreshStatus();
                        const cancelBtn = document.getElementById('btnCancelScan');
                        if (cancelBtn) {
                            const wrapper = cancelBtn.parentElement;
                            if (p.status === 'completed') {
                                wrapper.innerHTML = `<button class="btn btn-primary" onclick="location.hash='#/results?scanId=${p.scanId}'">View Results</button>`;
                            } else {
                                wrapper.innerHTML = `<button class="btn btn-secondary" onclick="location.hash='#/scan'">Start New Scan</button>`;
                            }
                        }
                        showToast(`Scan ${p.status}. ${p.totalLongPaths || 0} long paths found.`, p.status === 'completed' ? 'success' : 'warning');
                    }
                }
            } catch { /* ignore */ }
        };
        await update();
        scanPollTimer = setInterval(update, 2000);
    }

    // ═══════════════════════════════════════════════════════════
    // ── Results Page ───────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    let resultsState = { scanId: null, page: 1, pageSize: 50, sortColumn: 'path_total_length', sortDirection: 'desc' };

    async function renderResults() {
        const app = $('#app');
        const params = new URLSearchParams(window.location.hash.split('?')[1] || '');
        resultsState.scanId = params.get('scanId') ? parseInt(params.get('scanId')) : null;

        app.innerHTML = `
            <h2>Results</h2>
            <div class="card">
                <div class="form-row">
                    <div class="form-group">
                        <label>Scan</label>
                        <select id="resultsScanSelect"></select>
                    </div>
                    <div class="form-group">
                        <label>Search</label>
                        <input id="resultsSearch" placeholder="Filter by path or name...">
                    </div>
                    <div class="form-group">
                        <label>Extension</label>
                        <input id="resultsExtFilter" placeholder=".xlsx">
                    </div>
                    <div class="form-group">
                        <label>Fix Status</label>
                        <select id="resultsFixStatus">
                            <option value="">All</option>
                            <option value="pending">Pending</option>
                            <option value="fixed">Fixed</option>
                            <option value="failed">Failed</option>
                            <option value="skipped">Skipped</option>
                        </select>
                    </div>
                </div>
                <div style="display:flex;gap:8px;align-items:center">
                    <button class="btn btn-secondary" id="btnResultsSearch">Search</button>
                    <button class="btn btn-secondary" id="btnExportXlsx">Export XLSX</button>
                    <button class="btn btn-secondary" id="btnExportCsv">Export CSV</button>
                    <button class="btn btn-danger" id="btnDeleteScan" style="margin-left:auto">Delete Scan</button>
                </div>
            </div>
            <div id="resultsSummary"></div>
            <div class="card" id="resultsTable"><div class="empty-state"><p>Select a scan above.</p></div></div>
            <div id="resultsPagination"></div>`;

        // Populate scan select
        try {
            const res = await api.get('/scans');
            if (res.success) {
                const sel = document.getElementById('resultsScanSelect');
                sel.innerHTML = '<option value="">-- Select --</option>';
                (res.data || []).forEach(s => {
                    const opt = document.createElement('option');
                    opt.value = s.id;
                    opt.textContent = `#${s.id} — ${new Date(s.startedAt).toLocaleDateString()} (${s.status})`;
                    sel.appendChild(opt);
                });
                if (resultsState.scanId) sel.value = resultsState.scanId;
                sel.onchange = () => { resultsState.scanId = parseInt(sel.value) || null; resultsState.page = 1; loadResults(); };
            }
        } catch { }

        document.getElementById('btnResultsSearch').onclick = () => { resultsState.page = 1; loadResults(); };
        document.getElementById('resultsSearch').addEventListener('keydown', e => { if (e.key === 'Enter') { resultsState.page = 1; loadResults(); } });

        document.getElementById('btnExportXlsx').onclick = () => exportResults('xlsx');
        document.getElementById('btnExportCsv').onclick = () => exportResults('csv');
        document.getElementById('btnDeleteScan').onclick = async () => {
            if (!resultsState.scanId) return;
            if (!confirm(`Delete scan #${resultsState.scanId}?`)) return;
            const res = await api.del(`/scans/${resultsState.scanId}`);
            if (res.success) { showToast('Scan deleted', 'success'); navigate(); }
            else showToast(res.error || 'Delete failed', 'error');
        };

        if (resultsState.scanId) loadResults();
    }

    async function loadResults() {
        if (!resultsState.scanId) return;
        const search = document.getElementById('resultsSearch')?.value || '';
        const ext = document.getElementById('resultsExtFilter')?.value || '';
        const fixStatus = document.getElementById('resultsFixStatus')?.value || '';

        // Load summary
        try {
            const s = await api.get(`/scans/${resultsState.scanId}/summary`);
            if (s.success) {
                const d = s.data;
                document.getElementById('resultsSummary').innerHTML = `
                    <div class="stat-grid">
                        <div class="stat-card"><div class="stat-value">${formatNumber(d.totalItems)}</div><div class="stat-label">Total Items</div></div>
                        <div class="stat-card"><div class="stat-value">${formatNumber(d.fileCount)}</div><div class="stat-label">Files</div></div>
                        <div class="stat-card"><div class="stat-value">${formatNumber(d.folderCount)}</div><div class="stat-label">Folders</div></div>
                        <div class="stat-card"><div class="stat-value">${d.avgPathLength || 0}</div><div class="stat-label">Avg Path Length</div></div>
                        <div class="stat-card"><div class="stat-value">${d.maxPathLengthFound || 0}</div><div class="stat-label">Max Path Length</div></div>
                        <div class="stat-card"><div class="stat-value">${formatNumber(d.fixedCount)}</div><div class="stat-label">Fixed</div></div>
                        <div class="stat-card"><div class="stat-value">${d.uniqueSites || 0}</div><div class="stat-label">Sites</div></div>
                        <div class="stat-card"><div class="stat-value">${d.uniqueExtensions || 0}</div><div class="stat-label">Extensions</div></div>
                    </div>`;
            }
        } catch { }

        // Load items page
        try {
            let url = `/scans/${resultsState.scanId}/results?page=${resultsState.page}&pageSize=${resultsState.pageSize}`;
            url += `&sortColumn=${resultsState.sortColumn}&sortDirection=${resultsState.sortDirection}`;
            if (search) url += `&search=${encodeURIComponent(search)}`;
            if (ext) url += `&extension=${encodeURIComponent(ext)}`;
            if (fixStatus) url += `&fixStatus=${encodeURIComponent(fixStatus)}`;

            const res = await api.get(url);
            if (res.success) {
                const d = res.data;
                if (d.items && d.items.length > 0) {
                    const sortIcon = col => resultsState.sortColumn === col ? (resultsState.sortDirection === 'asc' ? '▲' : '▼') : '';
                    const sortClick = col => `onclick="window.__spfixSort('${col}')"`;

                    let html = `<div class="table-wrapper"><table class="results-table">
                        <tr>
                            <th ${sortClick('item_name')}>Name ${sortIcon('item_name')}</th>
                            <th ${sortClick('site_url')}>Site ${sortIcon('site_url')}</th>
                            <th ${sortClick('full_url')}>Path ${sortIcon('full_url')}</th>
                            <th ${sortClick('path_total_length')}>Length ${sortIcon('path_total_length')}</th>
                            <th ${sortClick('delta')}>Over By ${sortIcon('delta')}</th>
                            <th>Type</th>
                            <th>Ext</th>
                            <th class="fix-col" ${sortClick('fix_status')}>Fix Status ${sortIcon('fix_status')}</th>
                        </tr>`;

                    d.items.forEach(item => {
                        html += `<tr>
                            <td title="${escapeHtml(item.itemName)}">${escapeHtml(truncate(item.itemName, 50))}</td>
                            <td title="${escapeHtml(item.siteUrl)}">${escapeHtml(truncate(siteRelativePath(item.siteUrl), 30))}</td>
                            <td class="path-cell" title="${escapeHtml(item.fullUrl)}">${escapeHtml(item.fullUrl)}</td>
                            <td>${pathLengthBadge(item.pathTotalLength, item.maxAllowed || 400)}</td>
                            <td>${item.delta || ''}</td>
                            <td>${item.itemType || ''}</td>
                            <td>${item.itemExtension || ''}</td>
                            <td class="fix-col fix-status-${item.fixStatus || 'pending'}">${item.fixStatus || 'pending'}</td>
                        </tr>`;
                    });
                    html += '</table></div>';
                    document.getElementById('resultsTable').innerHTML = html;

                    // Pagination
                    const totalPages = Math.ceil(d.totalCount / resultsState.pageSize);
                    document.getElementById('resultsPagination').innerHTML = `
                        <div class="pagination">
                            <button ${resultsState.page <= 1 ? 'disabled' : ''} onclick="window.__spfixPage(${resultsState.page - 1})">← Prev</button>
                            <span class="page-info">Page ${resultsState.page} of ${totalPages} (${formatNumber(d.totalCount)} items)</span>
                            <button ${resultsState.page >= totalPages ? 'disabled' : ''} onclick="window.__spfixPage(${resultsState.page + 1})">Next →</button>
                        </div>`;
                } else {
                    document.getElementById('resultsTable').innerHTML = '<div class="empty-state"><div class="emoji">✅</div><p>No items match the current filters.</p></div>';
                    document.getElementById('resultsPagination').innerHTML = '';
                }
            }
        } catch (e) {
            document.getElementById('resultsTable').innerHTML = `<p style="color:var(--error)">Error loading results: ${e.message}</p>`;
        }
    }

    // Global handlers for inline onclick
    window.__spfixSort = (col) => {
        if (resultsState.sortColumn === col) resultsState.sortDirection = resultsState.sortDirection === 'asc' ? 'desc' : 'asc';
        else { resultsState.sortColumn = col; resultsState.sortDirection = 'desc'; }
        loadResults();
    };
    window.__spfixPage = (page) => { resultsState.page = page; loadResults(); };

    async function exportResults(format) {
        if (!resultsState.scanId) { showToast('Select a scan first', 'warning'); return; }
        try {
            const res = await api.getBlob(`/scans/${resultsState.scanId}/export?format=${format}`);
            if (!res.ok) { showToast('Export failed', 'error'); return; }
            const blob = await res.blob();
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `SPPathFixer_Scan${resultsState.scanId}.${format}`;
            a.click();
            URL.revokeObjectURL(url);
            showToast('Export downloaded', 'success');
        } catch (e) { showToast('Export failed: ' + e.message, 'error'); }
    }

    // ═══════════════════════════════════════════════════════════
    // ── Fix Page ───────────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    let fixPollTimer = null;
    const previewState = {
        scanId: null,
        batchId: null,
        page: 1,
        pageSize: 200,
        totalCount: 0,
        totalPages: 1
    };

    async function renderFix() {
        const app = $('#app');

        if (state.fixing) {
            app.innerHTML = `
                <h2>Fix in Progress</h2>
                <div class="card" id="fixProgressCard"><div id="fixProgressContent">Loading...</div></div>
                <div class="card"><h3>Log</h3><div class="log-area" id="fixLog"></div></div>
                <div id="fixCompletionResults"></div>`;
            pollFixProgress();
            return;
        }

        app.innerHTML = `
            <h2>Fix Long Paths</h2>
            <div class="card">
                <h3>Select Scan</h3>
                <div class="form-group">
                    <select id="fixScanSelect"></select>
                </div>
            </div>
            <div class="card">
                <h3>Fix Strategy</h3>
                <div class="form-group">
                    <label><input type="radio" name="fixStrategy" value="shorten_name" checked style="width:auto"> <strong>Shorten Names</strong> — Truncate file/folder names to bring the full path within the max length. Extensions are preserved.</label>
                </div>
                <div class="form-group">
                    <label><input type="radio" name="fixStrategy" value="move_up" style="width:auto"> <strong>Move Up</strong> — Move items up in the folder hierarchy to reduce path depth.</label>
                </div>
                <div class="form-group">
                    <label><input type="radio" name="fixStrategy" value="flatten_path" style="width:auto"> <strong>Flatten Path</strong> — Move items to the library root. Duplicate names are automatically suffixed (e.g. file_1.docx).</label>
                </div>
            </div>
            <div class="card">
                <h3>Path Length Limits</h3>
                <p style="color:var(--text-muted);font-size:0.85em;margin-bottom:12px">Maximum allowed full URL path length. Items exceeding these limits will be fixed.</p>
                <div style="display:flex;gap:16px;flex-wrap:wrap">
                    <div class="form-group" style="flex:1;min-width:200px">
                        <label for="fixMaxPath">Max Path Length (default)</label>
                        <input type="number" id="fixMaxPath" value="256" min="50" max="400" style="width:120px">
                    </div>
                    <div class="form-group" style="flex:1;min-width:200px">
                        <label for="fixMaxPathSpecial">Max Path Length (special extensions)</label>
                        <input type="number" id="fixMaxPathSpecial" value="218" min="50" max="400" style="width:120px">
                    </div>
                    <div class="form-group" style="flex:1;min-width:200px">
                        <label for="fixSpecialExts">Special Extensions</label>
                        <input type="text" id="fixSpecialExts" value=".xlsx,.xls" placeholder=".xlsx,.xls" style="width:200px">
                    </div>
                </div>
            </div>
            <div class="card">
                <h3>Options</h3>
                <div class="form-group">
                    <label><input type="checkbox" id="fixWhatIf" checked style="width:auto"> Preview only (WhatIf) — show what would change without making modifications</label>
                </div>
            </div>
            <div style="display:flex;gap:8px;margin-top:8px">
                <button class="btn btn-primary" id="btnStartFix">Start Fix</button>
            </div>
            <div id="fixPreviewResults" style="margin-top:16px"></div>`;
        // Populate scans
        try {
            const res = await api.get('/scans');
            if (res.success) {
                const sel = document.getElementById('fixScanSelect');
                sel.innerHTML = '<option value="">-- Select a completed scan --</option>';
                (res.data || []).filter(s => s.status === 'completed').forEach(s => {
                    const opt = document.createElement('option');
                    opt.value = s.id;
                    opt.textContent = `#${s.id} — ${new Date(s.startedAt).toLocaleDateString()} (${s.totalLongPaths || '?'} items)`;
                    sel.appendChild(opt);
                });
            }
        } catch { }

        // Only load special extensions from config (path length limits are independent fix-page defaults: 256/218)
        try {
            const cfgRes = await api.get('/config');
            if (cfgRes.success && cfgRes.data) {
                if (cfgRes.data.specialExtensions) document.getElementById('fixSpecialExts').value = cfgRes.data.specialExtensions;
            }
        } catch { }

        document.getElementById('btnStartFix').onclick = async () => {
            const scanId = parseInt(document.getElementById('fixScanSelect').value);
            if (!scanId) { showToast('Select a scan', 'warning'); return; }

            const strategy = document.querySelector('input[name="fixStrategy"]:checked').value;
            const whatIf = document.getElementById('fixWhatIf').checked;
            const targetMaxLength = parseInt(document.getElementById('fixMaxPath').value) || 256;
            const targetMaxLengthSpecial = parseInt(document.getElementById('fixMaxPathSpecial').value) || 218;
            const specialExtensions = document.getElementById('fixSpecialExts').value || '.xlsx,.xls';

            const fixBody = { strategy, applyToAll: true, targetMaxLength, targetMaxLengthSpecial, specialExtensions };
            const endpoint = whatIf ? `/scans/${scanId}/fix/preview` : `/scans/${scanId}/fix`;
            const btn = document.getElementById('btnStartFix');
            btn.disabled = true;
            btn.textContent = whatIf ? 'Running preview...' : 'Starting fix...';

            try {
                const res = await api.post(endpoint, fixBody);
                if (res.success) {
                    if (whatIf) {
                        previewState.scanId = scanId;
                        previewState.batchId = res.data?.batchId || null;
                        previewState.page = 1;
                        await waitForPreviewCompletion();
                        showToast('Preview complete', 'success');
                        await loadPreviewResults(scanId, 1);
                    } else {
                        showToast('Fix started!', 'success');
                        await refreshStatus();
                        navigate();
                    }
                } else {
                    showToast(res.error || 'Failed to start fix', 'error');
                }
            } catch (e) { showToast('Error: ' + e.message, 'error'); }
            btn.disabled = false;
            btn.textContent = 'Start Fix';
        };
    }

    async function waitForPreviewCompletion(timeoutMs = 180000) {
        const start = Date.now();
        while (Date.now() - start < timeoutMs) {
            const progress = await api.get('/fix/progress');
            if (!progress.success || !progress.data) {
                await new Promise(r => setTimeout(r, 500));
                continue;
            }

            const p = progress.data;
            const sameBatch = !previewState.batchId || p.batchId === previewState.batchId;
            if (sameBatch && (p.status === 'completed' || p.status === 'failed')) return;

            await new Promise(r => setTimeout(r, 500));
        }
    }

    async function loadPreviewResults(scanId, page = 1) {
        const container = document.getElementById('fixPreviewResults');
        if (!container) return;
        container.innerHTML = '<p>Loading preview results...</p>';

        previewState.scanId = scanId;
        previewState.page = Math.max(1, page);

        try {
            const res = await api.get(`/scans/${scanId}/results?fixStatus=preview&page=${previewState.page}&pageSize=${previewState.pageSize}`);
            if (res.success && res.data.items && res.data.items.length > 0) {
                const items = res.data.items;
                previewState.totalCount = res.data.totalCount || items.length;
                previewState.totalPages = res.data.totalPages || 1;

                const startItem = ((previewState.page - 1) * previewState.pageSize) + 1;
                const endItem = Math.min(previewState.page * previewState.pageSize, previewState.totalCount);

                let html = `<h3>Preview Results</h3>
                    <p style="color:var(--text-muted);font-size:0.85em;margin-bottom:8px">Showing ${formatNumber(startItem)}-${formatNumber(endItem)} of ${formatNumber(previewState.totalCount)} preview items.</p>
                    <p style="color:var(--text-muted);font-size:0.85em;margin-bottom:12px">This is a preview — no changes have been made. Click &quot;Apply These Changes&quot; to execute.</p>
                    <div class="table-wrapper"><table>
                        <tr><th>Item Name</th><th>Path</th><th>Length</th><th>New Name</th><th>Description</th></tr>`;
                items.forEach(item => {
                    const nameChanged = item.fixNewName && item.fixNewName !== item.itemName;
                    html += `<tr>
                        <td title="${escapeHtml(item.itemName)}">${escapeHtml(truncate(item.itemName, 40))}</td>
                        <td class="path-cell" title="${escapeHtml(item.fullUrl)}">${escapeHtml(truncate(siteRelativePath(item.fullUrl), 60))}</td>
                        <td>${item.pathTotalLength}</td>
                        <td style="${nameChanged ? 'color:var(--success);font-weight:600' : ''}">${escapeHtml(item.fixNewName || item.itemName)}</td>
                        <td style="font-size:0.85em">${escapeHtml(item.fixResult || '-')}</td>
                    </tr>`;
                });
                html += '</table></div>';
                html += `<div class="pagination" style="margin-top:10px">
                    <button ${previewState.page <= 1 ? 'disabled' : ''} onclick="window.__spfixPreviewPage(${previewState.page - 1})">← Prev</button>
                    <span class="page-info">Page ${previewState.page} of ${previewState.totalPages}</span>
                    <button ${previewState.page >= previewState.totalPages ? 'disabled' : ''} onclick="window.__spfixPreviewPage(${previewState.page + 1})">Next →</button>
                </div>`;
                html += `<div style="display:flex;gap:8px;margin-top:12px">
                    <button class="btn btn-primary" id="btnApplyFix">Apply These Changes</button>
                    <button class="btn btn-secondary" onclick="location.hash='#/results?scanId=${scanId}'">View in Results</button>
                </div>`;
                container.innerHTML = html;

                window.__spfixPreviewPage = (nextPage) => {
                    if (!previewState.scanId) return;
                    loadPreviewResults(previewState.scanId, nextPage);
                };

                document.getElementById('btnApplyFix').onclick = async () => {
                    if (!confirm('Apply all previewed changes? This will modify files in SharePoint.')) return;
                    const strategy = document.querySelector('input[name="fixStrategy"]:checked')?.value || 'shorten_name';
                    const targetMaxLength = parseInt(document.getElementById('fixMaxPath')?.value) || 256;
                    const targetMaxLengthSpecial = parseInt(document.getElementById('fixMaxPathSpecial')?.value) || 218;
                    const specialExtensions = document.getElementById('fixSpecialExts')?.value || '.xlsx,.xls';
                    try {
                        const r = await api.post(`/scans/${scanId}/fix`, { strategy, applyToAll: true, targetMaxLength, targetMaxLengthSpecial, specialExtensions });
                        if (r.success) {
                            showToast('Fix started!', 'success');
                            await refreshStatus();
                            navigate();
                        } else { showToast(r.error || 'Fix failed', 'error'); }
                    } catch (e) { showToast('Error: ' + e.message, 'error'); }
                };
            } else {
                container.innerHTML = '<div class="empty-state"><div class="emoji">✅</div><p>No items would be changed by this strategy.</p></div>';
            }
        } catch (e) {
            container.innerHTML = `<p style="color:var(--error)">Failed to load preview: ${e.message}</p>`;
        }
    }

    async function loadFixResults(scanId) {
        const container = document.getElementById('fixCompletionResults');
        if (!container) return;
        container.innerHTML = '<p>Loading fix results...</p>';
        try {
            // Fetch fixed, failed, and skipped items
            const [fixedRes, failedRes, skippedRes] = await Promise.all([
                api.get(`/scans/${scanId}/results?fixStatus=fixed&pageSize=500`),
                api.get(`/scans/${scanId}/results?fixStatus=failed&pageSize=500`),
                api.get(`/scans/${scanId}/results?fixStatus=skipped&pageSize=500`)
            ]);
            const fixedItems = (fixedRes.success && fixedRes.data.items) ? fixedRes.data.items : [];
            const failedItems = (failedRes.success && failedRes.data.items) ? failedRes.data.items : [];
            const skippedItems = (skippedRes.success && skippedRes.data.items) ? skippedRes.data.items : [];
            const total = fixedItems.length + failedItems.length + skippedItems.length;

            if (total === 0) {
                container.innerHTML = '<div class="card"><div class="empty-state"><div class="emoji">✅</div><p>No items were processed.</p></div></div>';
                return;
            }

            let html = `<div class="card"><h3>Fix Results</h3>
                <div class="stat-grid" style="margin-bottom:12px">
                    <div class="stat-card"><div class="stat-value" style="color:var(--success)">${fixedItems.length}</div><div class="stat-label">Fixed</div></div>
                    <div class="stat-card"><div class="stat-value" style="color:var(--error)">${failedItems.length}</div><div class="stat-label">Failed</div></div>
                    <div class="stat-card"><div class="stat-value" style="color:var(--warning, #FF9800)">${skippedItems.length}</div><div class="stat-label">Skipped (stale)</div></div>
                </div>`;

            if (fixedItems.length > 0) {
                html += `<h4 style="margin-top:12px">Successfully Fixed</h4>
                    <div class="table-wrapper"><table>
                        <tr><th>Item Name</th><th>Path</th><th>Length</th><th>New Name</th><th>Details</th></tr>`;
                fixedItems.forEach(item => {
                    const nameChanged = item.fixNewName && item.fixNewName !== item.itemName;
                    html += `<tr>
                        <td title="${escapeHtml(item.itemName)}">${escapeHtml(truncate(item.itemName, 40))}</td>
                        <td class="path-cell" title="${escapeHtml(item.fullUrl)}">${escapeHtml(truncate(siteRelativePath(item.fullUrl), 60))}</td>
                        <td>${item.pathTotalLength}</td>
                        <td style="${nameChanged ? 'color:var(--success);font-weight:600' : ''}">${escapeHtml(item.fixNewName || item.itemName)}</td>
                        <td style="font-size:0.85em">${escapeHtml(item.fixResult || '-')}</td>
                    </tr>`;
                });
                html += '</table></div>';
            }

            if (failedItems.length > 0) {
                html += `<h4 style="margin-top:16px;color:var(--error)">Failed</h4>
                    <div class="table-wrapper"><table>
                        <tr><th>Item Name</th><th>Path</th><th>Length</th><th>Error</th></tr>`;
                failedItems.forEach(item => {
                    html += `<tr>
                        <td title="${escapeHtml(item.itemName)}">${escapeHtml(truncate(item.itemName, 40))}</td>
                        <td class="path-cell" title="${escapeHtml(item.fullUrl)}">${escapeHtml(truncate(siteRelativePath(item.fullUrl), 60))}</td>
                        <td>${item.pathTotalLength}</td>
                        <td style="font-size:0.85em;color:var(--error)">${escapeHtml(item.fixResult || 'Unknown error')}</td>
                    </tr>`;
                });
                html += '</table></div>';
            }

            if (skippedItems.length > 0) {
                html += `<h4 style="margin-top:16px;color:var(--warning, #FF9800)">Skipped (Stale)</h4>
                    <div class="table-wrapper"><table>
                        <tr><th>Item Name</th><th>Path</th><th>Length</th><th>Reason</th></tr>`;
                skippedItems.forEach(item => {
                    html += `<tr>
                        <td title="${escapeHtml(item.itemName)}">${escapeHtml(truncate(item.itemName, 40))}</td>
                        <td class="path-cell" title="${escapeHtml(item.fullUrl)}">${escapeHtml(truncate(siteRelativePath(item.fullUrl), 60))}</td>
                        <td>${item.pathTotalLength}</td>
                        <td style="font-size:0.85em;color:var(--warning, #FF9800)">${escapeHtml(item.fixResult || 'Item changed since scan')}</td>
                    </tr>`;
                });
                html += '</table></div>';
            }

            html += `<div style="display:flex;gap:8px;margin-top:12px">
                <button class="btn btn-secondary" onclick="location.hash='#/results?scanId=${scanId}'">View Full Results</button>
                <button class="btn btn-primary" onclick="location.hash='#/fix'">Back to Fix Page</button>
            </div></div>`;
            container.innerHTML = html;
        } catch (e) {
            container.innerHTML = `<p style="color:var(--error)">Failed to load fix results: ${e.message}</p>`;
        }
    }

    async function pollFixProgress() {
        if (fixPollTimer) clearInterval(fixPollTimer);
        const update = async () => {
            try {
                const res = await api.get('/fix/progress');
                if (res.success) {
                    const p = res.data;
                    const pct = p.overallPercent || 0;
                    const processed = (p.fixedItems || 0) + (p.failedItems || 0);
                    const total = p.totalItems || 0;
                    document.getElementById('fixProgressContent').innerHTML = `
                        <p><strong>Status:</strong> ${p.status || 'running'}</p>
                        <p><strong>Strategy:</strong> ${p.strategy || '-'}</p>
                        <p><strong>Progress:</strong> ${processed} / ${total} items (${p.fixedItems || 0} fixed, ${p.failedItems || 0} failed)</p>
                        <div class="progress-bar"><div class="progress-fill" style="width:${pct}%"></div></div>
                        <p style="font-size:0.85em;color:var(--text-muted)">${pct}% complete</p>`;

                    if (p.recentLogs && p.recentLogs.length) {
                        const logArea = document.getElementById('fixLog');
                        logArea.innerHTML = p.recentLogs.map(l =>
                            `<div class="log-entry log-${l.level || 'info'}">[${l.timestamp ? new Date(l.timestamp).toLocaleTimeString() : ''}] ${l.message}</div>`
                        ).join('');
                        logArea.scrollTop = logArea.scrollHeight;
                    }

                    if (p.status === 'completed' || p.status === 'failed') {
                        clearInterval(fixPollTimer);
                        await refreshStatus();
                        showToast(p.status === 'completed' ? 'Fix operation completed' : 'Fix operation completed with errors', p.status === 'completed' ? 'success' : 'warning');
                        const scanId = p.scanId || state.activeScanId;
                        if (scanId) await loadFixResults(scanId);
                    }
                }
            } catch { }
        };
        await update();
        fixPollTimer = setInterval(update, 2000);
    }

    // ═══════════════════════════════════════════════════════════
    // ── Settings Page ──────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    async function renderSettings() {
        const app = $('#app');
        app.innerHTML = `
            <h2>Settings</h2>
            <div class="card" id="settingsCard"><p style="color:var(--text-muted)">Loading...</p></div>
            <div class="card">
                <h3>Connection</h3>
                <p id="settingsConn"></p>
                <button class="btn btn-danger" id="btnDisconnect" style="margin-top:12px;display:none">Disconnect</button>
            </div>`;

        try {
            const res = await api.get('/config');
            if (res.success) {
                const c = res.data;
                document.getElementById('settingsCard').innerHTML = `
                    <h3>Scan Defaults</h3>
                    <div class="form-row">
                        <div class="form-group">
                            <label>GUI Port</label>
                            <input type="number" id="setGuiPort" value="${c.guiPort || 8080}">
                        </div>
                        <div class="form-group">
                            <label>Max Path Length</label>
                            <input type="number" id="setMaxPath" value="${c.maxPathLength || 400}">
                        </div>
                        <div class="form-group">
                            <label>Max Path Length (Special)</label>
                            <input type="number" id="setMaxPathSpecial" value="${c.maxPathLengthSpecial || 260}">
                        </div>
                    </div>
                    <div class="form-row">
                        <div class="form-group">
                            <label>Special Extensions</label>
                            <input id="setSpecialExt" value="${c.specialExtensions || '.xlsx,.xlsm,.xltx'}">
                            <span style="font-size:0.8em;color:var(--text-muted)">Extensions that have lower path limits (e.g. Excel OneNote)</span>
                        </div>
                        <div class="form-group">
                            <label>Extension Filter</label>
                            <input id="setExtFilter" value="${c.extensionFilter || ''}">
                            <span style="font-size:0.8em;color:var(--text-muted)">Only scan these extensions (empty = all)</span>
                        </div>
                    </div>
                    <div class="form-row">
                        <div class="form-group">
                            <label>Max Threads</label>
                            <input type="number" id="setMaxThreads" value="${c.maxThreads || 4}" min="1" max="16">
                        </div>
                        <div class="form-group">
                            <label>Default Export Format</label>
                            <select id="setOutputFormat">
                                <option value="XLSX" ${c.outputFormat === 'XLSX' ? 'selected' : ''}>XLSX</option>
                                <option value="CSV" ${c.outputFormat === 'CSV' ? 'selected' : ''}>CSV</option>
                            </select>
                        </div>
                    </div>
                    <button class="btn btn-primary" id="btnSaveSettings" style="margin-top:8px">Save Settings</button>`;

                document.getElementById('btnSaveSettings').onclick = async () => {
                    const body = {
                        guiPort: parseInt(document.getElementById('setGuiPort').value),
                        maxPathLength: parseInt(document.getElementById('setMaxPath').value),
                        maxPathLengthSpecial: parseInt(document.getElementById('setMaxPathSpecial').value),
                        specialExtensions: document.getElementById('setSpecialExt').value,
                        extensionFilter: document.getElementById('setExtFilter').value,
                        maxThreads: parseInt(document.getElementById('setMaxThreads').value),
                        outputFormat: document.getElementById('setOutputFormat').value
                    };
                    const r = await api.put('/config', body);
                    if (r.success) showToast('Settings saved', 'success');
                    else showToast(r.error || 'Save failed', 'error');
                };
            }
        } catch { }

        if (state.connected) {
            document.getElementById('settingsConn').textContent = `Connected to ${state.tenantDomain || 'unknown'} as ${state.userPrincipalName || 'app'} (${state.authMode || 'unknown'})`;
            const btn = document.getElementById('btnDisconnect');
            btn.style.display = 'inline-flex';
            btn.onclick = async () => {
                await api.post('/disconnect');
                await refreshStatus();
                showToast('Disconnected', 'info');
                navigate();
            };
        } else {
            document.getElementById('settingsConn').textContent = 'Not connected';
        }
    }

    // ── Utility ─────────────────────────────────────────────────
    function escapeHtml(str) {
        if (!str) return '';
        return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    }
    function truncate(str, len) {
        if (!str || str.length <= len) return str || '';
        return str.slice(0, len - 1) + '…';
    }

    // ── Bootstrap ───────────────────────────────────────────────
    async function init() {
        initTheme();
        await refreshStatus();
        navigate();
        pollTimer = setInterval(refreshStatus, 5000);
    }

    window.addEventListener('hashchange', navigate);
    window.addEventListener('DOMContentLoaded', init);
})();
