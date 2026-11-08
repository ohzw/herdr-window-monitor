import { View, div, image } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import {
  appHome, closeOverlay, exec, focused, hc, nextCommand, openOverlay, panes, props, readTextFile, run,
  setShared, shared, spaces, theme, writeTextFile,
} from "herdr";
import { text } from "./i18n.js";

// The folder this mod was installed as (renamed on a name clash). Herdr has no
// API for it; the module path is in any stack trace.
const INSTALLED_AS = /\/mods\/([^/]+)\/main\.js/.exec(new Error().stack ?? "")?.[1] ?? "window-monitor";
const SCREEN_RECORDING_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";
// How often the open picker re-lists windows and retakes their thumbnails.
const THUMBNAIL_REFRESH_MS = 2000;
// Frame rates the settings offer (the helper's --fps); 2 is the default.
const FPS_CHOICES = [1, 2, 5, 10, 20];
const DEFAULT_FPS = 2;

// Removes frame folders left by copies whose Herdr process is gone (crash or
// forced quit: their close() never ran). Live copies, in this or another
// Herdr process, keep theirs: a folder is kept while its control file names a
// running process, or for a minute if it has no control file yet.
const STALE_CLEANUP = `
for d in "$1"-feed-*; do
  [ -d "$d" ] || continue
  [ "$d" = "$2" ] && continue
  pid=$(sed -n 's/^gui_pid=//p' "$d/control" 2>/dev/null)
  if [ -f "$d/control" ]; then
    # Live copies rewrite their control file every 2 seconds.
    [ -n "$(find "$d/control" -mmin -1)" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && continue
  else [ -n "$(find "$d" -maxdepth 0 -mmin -1)" ] && continue; fi
  rm -rf "$d"
done`;

function checked(result) {
  if (result.code !== 0) throw new Error(result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`);
  return result.stdout;
}

function message(e) { return String(e).replace(/^Error: /, ""); }

async function systemLanguage() {
  const result = await exec("/usr/bin/defaults", ["read", "-g", "AppleLanguages"]);
  return /^\(?\s*"?ja/.test(result.stdout.trim()) ? "ja" : "en";
}

// One mod, three roles: the pane (default), and two dialogs it opens with
// props.role "picker" (choose a window) and "settings" (the wait setting).
export default class WindowMonitor extends View {
  init(_props, cx) {
    this.config = props() ?? {};
    this.modName = this.config.modName ?? INSTALLED_AS;
    this.settingsKey = `${this.modName}:settings`;
    this.lang = this.config.lang ?? "en";
    this.role = this.config.overlay ? this.config.role : "pane";
    if (this.role === "picker") return this.initPicker(cx);
    if (this.role === "settings") return this.initSettings(cx);
    this.initPane(cx);
  }

  get t() { return text[this.lang]; }
  get settings() { return shared(this.settingsKey) ?? {}; }
  saveSettings(change) { setShared(this.settingsKey, { ...this.settings, ...change }); }

  // MARK: pane

  initPane(cx) {
    this.helper = this.config.helper ?? `${appHome()}/mods/${this.modName}/.bin/window-monitor-helper`;
    // The picker lists and photographs windows with a copy of the helper at
    // another path: a process of the helper's own path interrupts its captures.
    this.lister = this.config.lister ?? `${this.helper.replace(/\/[^/]*$/, "")}/window-monitor-lister`;
    this.instance = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    this.startedAt = Date.now();
    this.candidates = new Set();
    this.picksKey = `${this.modName}:picks`;
    this.claimsKey = `${this.modName}:panes`;
    // Outside the mod folder: saving a file there reloads the mod. Any other
    // folder under mods/ is still watched, so Herdr drops a deleted image.
    this.relative = `mods/${this.modName}-feed-${this.instance}`;
    this.directory = `${appHome()}/${this.relative}`;
    this.control = `${this.directory}/control`;
    this.setup = "checking";
    this.pane = this.config.pane ?? null;
    this.guiPID = 0;
    this.guiWindow = 0;
    this.selected = null;
    this.lastPick = 0;
    this.terminal = null;
    this.enabled = false;
    this.closed = false;
    this.busy = false;
    this.polling = false;
    this.reading = false;
    this.live = false;
    this.frameTimer = null;
    this.hovered = false;
    this.error = "";
    this.messageKey = "idle";
    this.frame = -1;
    this.file = null;
    this.previousFile = null;
    this.sessions = 0;
    this.sessionDirectory = null;
    this.lastControl = "";
    this.lastHeartbeat = 0;
    this.size = { width: 640, height: 480 };
    this.bindPane();
    cx.spawn(async (cx) => {
      try {
        this.lang = await systemLanguage();
        cx.notify();
        this.guiPID = Number(checked(await exec("/bin/sh", ["-c", "echo $PPID"])).trim());
        checked(await exec("/bin/mkdir", ["-p", this.directory]));
        checked(await exec("/bin/sh", ["-c", STALE_CLEANUP, "sh", `${appHome()}/mods/${this.modName}`, this.directory]));
        await this.prepare();
        if (this.closed) await this.removeOwnedFiles();
      } catch (e) { this.error = message(e); }
      cx.notify();
    });
    cx.timer.every(500, (cx) => {
      this.bindPane();
      this.takePick(cx);
      if (this.waitingForPane && this.pane) this.action("start", cx);
      this.poll(cx);
    });
    cx.spawn(async (cx) => {
      for (;;) this.action(await nextCommand(), cx);
    });
  }

  get publishDelayMs() { return this.config.publishDelayMs ?? this.settings.delayMs ?? 0; }
  get fps() { return FPS_CHOICES.includes(this.settings.fps) ? this.settings.fps : DEFAULT_FPS; }

  // Helper built, permission granted, display window known; then the picker.
  async prepare() {
    this.setup = "checking";
    this.error = "";
    if ((await exec("/bin/test", ["-x", this.helper])).code !== 0
      || (await exec("/bin/test", ["-x", this.lister])).code !== 0) { this.setup = "build"; return; }
    const permission = JSON.parse(checked(await exec(this.helper, ["--permission"])));
    if (!permission.granted) { this.setup = "permission"; return; }
    const ids = JSON.parse(checked(await exec(this.helper, ["--gui-windows-for-pid", String(this.guiPID)])));
    this.guiWindow = Number(this.config.guiWindow ?? (ids.length === 1 ? ids[0] : 0));
    if (!this.guiWindow) throw new Error(this.t.noGuiWindow);
    await this.writeControl("pause", true);
    this.setup = "ready";
    if (!this.closed) this.openPicker();
  }

  openPicker() {
    openOverlay({
      mod: this.modName, kind: "dialog", width: 760, height: 560,
      props: {
        role: "picker", owner: this.instance, picksKey: this.picksKey, lister: this.lister, guiPID: this.guiPID,
        thumbs: this.relative, lang: this.lang, current: this.selected?.id ?? null,
      },
    });
  }

  openSettings() {
    openOverlay({
      mod: this.modName, kind: "dialog", width: 520, height: 440,
      props: { role: "settings", lang: this.lang, fixed: this.config.publishDelayMs ?? null },
    });
  }

  // The picker hands its choice over through shared state, keyed by this copy.
  takePick(cx) {
    if (this.closed || this.busy) return;
    const picks = shared(this.picksKey) ?? {};
    const pick = picks[this.instance];
    if (!pick) return;
    const { [this.instance]: _, ...rest } = picks;
    setShared(this.picksKey, rest);
    this.selected = pick.window;
    this.action("start", cx);
  }

  // Herdr doesn't tell a pane mod which pane it is. Each copy claims one in
  // shared state and refreshes the claim. Until the person clicks in it, a
  // copy guesses: the pane no live copy holds (focus may still be on the old
  // one), among the panes seen in its first 2 seconds. A copy starts when its
  // pane first shows, and that pane enters panes() just after, so a pane made
  // later is never its own; this keeps a copy left over from a mod reload off
  // new panes. A click is certain (the clicked pane gets focus); a certain
  // claim wins over a guess, and the copy that guessed that pane guesses again.
  bindPane() {
    const now = Date.now();
    const live = panes().filter((p) => p.mod === this.modName);
    if (now - this.startedAt < 2000) for (const p of live) this.candidates.add(p.pane);
    const claims = shared(this.claimsKey) ?? {};
    const held = (c) => c && c.instance !== this.instance && now - c.at <= 6000;
    if (this.pane && live.some((p) => p.pane === this.pane)
      && (this.sure || this.config.pane || !(held(claims[this.pane]) && claims[this.pane].sure))) {
      if (!this.config.pane && now - (this.claimedAt ?? 0) > 2000) this.claim(live, now);
      return;
    }
    if (this.config.pane) return;
    this.sure = false;
    const free = live.filter((p) => this.candidates.has(p.pane) && !held(claims[p.pane]));
    const pick = free.find((p) => p.pane === focused()?.pane) ?? (free.length === 1 ? free[0] : null);
    this.pane = pick?.pane ?? null;
    if (this.pane) this.claim(live, now);
  }

  // A press in this pane focuses it; read the focus once Herdr has moved it.
  learnPane(cx) {
    if (this.config.pane) return;
    cx.timer.after(150, (cx) => {
      const pane = focused()?.pane;
      const live = panes().filter((p) => p.mod === this.modName);
      if (this.closed || !pane || !live.some((p) => p.pane === pane)) return;
      const changed = pane !== this.pane;
      this.pane = pane;
      this.sure = true;
      this.claim(live, Date.now());
      if (changed) cx.notify();
    });
  }

  claim(live, now) {
    const claims = Object.fromEntries(Object.entries(shared(this.claimsKey) ?? {})
      .filter(([pane, c]) => pane !== this.pane && c.instance !== this.instance && live.some((p) => p.pane === pane)));
    if (this.pane && !this.closed) {
      claims[this.pane] = { instance: this.instance, at: now, target: this.terminal ? this.selected?.id : null, sure: Boolean(this.sure) };
    }
    this.claimedAt = now;
    setShared(this.claimsKey, claims);
  }

  shown() {
    this.bindPane();
    const pane = panes().find((p) => p.pane === this.pane);
    const tab = spaces().find((s) => s.active)?.tabs.find((t) => t.active);
    return Boolean(pane && tab?.id === pane.tab && (!tab.zoomed || pane.zoomed));
  }

  async writeControl(state, force = false) {
    if (!this.guiPID || !this.guiWindow) return;
    const body = `state=${state}\ngui_pid=${this.guiPID}\ngui_window=${this.guiWindow}\nowner=${this.instance}\n`;
    if (!force && body === this.lastControl && Date.now() - this.lastHeartbeat < 2000) return;
    const previous = await readTextFile(this.control);
    await writeTextFile(this.control, body, previous);
    this.lastControl = body;
    this.lastHeartbeat = Date.now();
  }

  // Deletes this copy's current frame session (images, metadata, stats). Call
  // after the helper was told to stop and the images are no longer shown.
  async removeSession() {
    const directory = this.sessionDirectory;
    this.sessionDirectory = null;
    this.file = null;
    this.previousFile = null;
    if (directory) checked(await exec("/bin/rm", ["-rf", directory]));
  }

  async removeOwnedFiles() {
    checked(await exec("/bin/rm", ["-rf", this.directory]));
  }

  async start(cx) {
    this.bindPane();
    if (!this.guiWindow || !this.selected) throw new Error(this.t.notReady);
    // Without its pane the copy can't tell when the pane is hidden; start
    // once a click (or a free pane) tells which one it is.
    this.waitingForPane = !this.pane;
    if (this.waitingForPane) { this.messageKey = "clickPane"; return; }
    const delay = this.publishDelayMs;
    if (!Number.isInteger(delay) || delay < 0 || delay > 500) throw new Error(this.t.badDelay);
    const fps = this.fps;
    this.stopFrameTimer();
    if (this.terminal) {
      await this.writeControl("stop", true);
      checked(await hc(["kill", this.terminal, "--json"]));
      this.terminal = null;
    }
    await this.removeSession();
    // A new folder per start: a restarted helper counts from frame-0 again,
    // and Herdr caches images by path, so names must never repeat.
    this.sessions += 1;
    this.sessionRelative = `${this.relative}/frames-${this.sessions}`;
    this.sessionDirectory = `${appHome()}/${this.sessionRelative}`;
    checked(await exec("/bin/mkdir", ["-p", this.sessionDirectory]));
    this.frame = -1;
    this.enabled = true;
    await this.writeControl(this.shown() ? "run" : "pause", true);
    const result = JSON.parse(checked(await hc(["run", "--bg", "--json", "--no-parent", "--no-notify", "--",
      this.helper, "--window-id", String(this.selected.id), "--fps", String(fps), "--max-edge", "1280",
      "--png-dir", this.sessionDirectory, "--publish-delay-ms", String(delay),
      "--stats", `${this.sessionDirectory}/stats.json`, "--control", this.control])));
    this.terminal = result.address;
    if (!this.terminal) throw new Error("hc run returned no terminal address");
    if (this.closed) {
      await hc(["kill", this.terminal, "--json"]);
      return;
    }
    this.frameTimer = cx.timer.every(Math.round(1000 / fps), (cx) => this.readFrame(cx));
    this.saveSettings({ target: { app: this.selected.app, title: this.selected.title } });
    this.messageKey = "starting";
    this.claimedAt = 0; // publish the new target with the next claim
  }

  stopFrameTimer() {
    this.frameTimer?.cancel();
    this.frameTimer = null;
    this.live = false;
  }

  async stop(cx) {
    this.enabled = false;
    this.waitingForPane = false;
    this.stopFrameTimer();
    await this.writeControl("stop", true);
    if (this.terminal) checked(await hc(["kill", this.terminal, "--json"]));
    this.terminal = null;
    this.messageKey = "stopped";
    this.claimedAt = 0;
    cx.notify(); // unmount the images before their files disappear
    await this.removeSession();
  }

  action(command, cx) {
    if (this.closed || this.busy) return;
    if (command === "choose") { if (this.setup === "ready") this.openPicker(); return; }
    if (command === "settings") { this.openSettings(); return; }
    // Each task gets the cx of the spawned task: a click's cx is only valid
    // during the click.
    const tasks = {
      build: async (cx) => {
        this.setup = "building";
        cx.notify();
        const result = await exec("/bin/sh", [`${appHome()}/mods/${this.modName}/helper/build.sh`]);
        if (result.code !== 0) {
          this.setup = "build";
          throw new Error(this.t.buildFailed(result.stderr.trim().split("\n").slice(-3).join(" ") || `exit ${result.code}`));
        }
        await this.prepare();
      },
      "request-permission": async () => { await exec(this.helper, ["--request-permission"]); await this.prepare(); },
      "open-settings": async () => { checked(await exec("/usr/bin/open", [SCREEN_RECORDING_SETTINGS])); },
      retry: () => this.prepare(),
      start: (cx) => this.start(cx),
      stop: (cx) => this.stop(cx),
    };
    if (!tasks[command]) return;
    this.busy = true;
    cx.spawn(async (cx) => {
      try {
        this.error = "";
        await tasks[command](cx);
      } catch (e) { this.error = message(e); }
      this.busy = false;
      cx.notify();
    });
  }

  poll(cx) {
    if (this.closed || this.polling || this.busy) return;
    if (!this.terminal) {
      // Keep the control file fresh while idle, so cleanup can tell a live
      // copy's folder from one left behind by a reload or crash.
      if (this.setup === "ready") cx.spawn(async () => { try { await this.writeControl("pause"); } catch (_) {} });
      return;
    }
    this.polling = true;
    const address = this.terminal;
    cx.spawn(async (cx) => {
      try {
        const visible = this.shown();
        await this.writeControl(this.enabled && visible ? "run" : "pause");
        if (this.closed || this.terminal !== address) return;
        const raw = await readTextFile(`${this.sessionDirectory}/stats.json`);
        const stats = raw ? JSON.parse(raw) : null;
        if (this.closed || this.terminal !== address) return;
        let messageKey = visible ? "watching" : "pausedPane";
        if (stats && !stats.running && visible) messageKey = "pausedGui";
        if (stats?.exit_reason) {
          this.enabled = false;
          this.error = stats.exit_reason.startsWith("target window is gone") ? this.t.targetGone : stats.exit_reason;
          messageKey = "ended";
        }
        const terminal = JSON.parse(checked(await hc(["get", address, "--json"])));
        if (this.closed || this.terminal !== address) return;
        if (terminal.finished_ms != null) {
          this.enabled = false;
          this.terminal = null;
          this.stopFrameTimer();
          messageKey = "ended";
          if (terminal.exit_code !== 0 && !this.error) this.error = this.t.helperExit(terminal.exit_code);
        }
        const changed = messageKey !== this.messageKey;
        this.messageKey = messageKey;
        // Frames are read by the frame timer, at the capture's frame rate.
        this.live = visible && this.enabled;
        if (changed && visible) cx.notify();
      } catch (e) {
        this.error = message(e);
        if (this.shown()) cx.notify();
      } finally {
        this.polling = false;
      }
    });
  }

  // Shows the helper's newest image; runs once per frame interval while live.
  readFrame(cx) {
    if (this.closed || this.busy || this.reading || !this.live || !this.terminal) return;
    this.reading = true;
    const address = this.terminal;
    cx.spawn(async (cx) => {
      try {
        const metadata = await readTextFile(`${this.sessionDirectory}/current.json`);
        if (this.closed || this.terminal !== address || !this.live || !metadata) return;
        const frame = JSON.parse(metadata);
        if (frame.frame === this.frame) return;
        this.frame = frame.frame;
        this.imageWidth = frame.width;
        this.imageHeight = frame.height;
        // The previous image stays underneath: image() paints nothing
        // while the new file loads or reloads after its change event.
        this.previousFile = this.file;
        this.file = `${this.sessionRelative}/${frame.file.split("/").pop()}`;
        cx.notify();
      } catch (e) {
        this.error = message(e);
        cx.notify();
      } finally {
        this.reading = false;
      }
    });
  }

  async close() {
    if (this.role === "picker") return this.closePicker();
    if (this.role !== "pane") return;
    this.closed = true;
    this.enabled = false;
    this.stopFrameTimer();
    if (this.terminal) run("terminal.kill", { terminal: this.terminal });
    if (this.guiPID && this.guiWindow) await this.writeControl("stop", true);
    this.claim(panes().filter((p) => p.mod === this.modName), Date.now());
    // The helper also exits once the control file is gone (lease check).
    await this.removeOwnedFiles();
  }

  // MARK: picker dialog

  initPicker(cx) {
    this.windows = [];
    this.selected = null;
    this.pinned = null;
    this.loading = true;
    this.refreshing = false;
    this.closed = false;
    this.error = "";
    this.size = { width: 760, height: 560 };
    // Thumbnails: each refresh writes a new folder (Herdr caches images by
    // path). The newest two are kept so the previous picture stays under the
    // new one while it loads; older folders are deleted.
    this.generations = [];
    this.generation = 0;
    this.thumbs = new Map();
    this.previousThumbs = new Map();
    this.refreshWindows(cx);
    cx.timer.every(THUMBNAIL_REFRESH_MS, (cx) => this.refreshWindows(cx));
    cx.spawn(async (cx) => {
      for (;;) {
        const command = await nextCommand();
        if (command.startsWith("select-")) this.select(Number(command.slice(7)), cx);
        else if (command === "pick") this.pick();
        else if (command === "cancel") closeOverlay(this.config.overlay);
      }
    });
  }

  refreshWindows(cx) {
    if (this.refreshing || this.closed) return;
    this.refreshing = true;
    this.generation += 1;
    const folder = `${this.config.thumbs}/thumbs-${Date.now()}-${this.generation}`;
    cx.spawn(async (cx) => {
      try {
        // Listed before the lister runs, so closing removes it even mid-run
        // (closing cancels this task); the lister never recreates it.
        this.generations.push(folder);
        checked(await exec("/bin/mkdir", [`${appHome()}/${folder}`]));
        const rows = JSON.parse(checked(await exec(this.config.lister, ["--list-windows",
          "--exclude-pid", String(this.config.guiPID), "--thumbnails", `${appHome()}/${folder}`, "--thumb-edge", "480"])));
        if (this.closed) return;
        this.previousThumbs = this.thumbs;
        this.thumbs = new Map(rows.filter((w) => w.thumbnail).map((w) => [w.id, `${folder}/${w.thumbnail}`]));
        const first = this.pinned == null;
        // Window IDs change when an app restarts, so remember app and title.
        // Two captures of one window interrupt each other: skip watched ones.
        const taken = this.watchedElsewhere();
        const free = rows.filter((w) => !taken.has(w.id));
        const last = this.settings.target;
        const sameApp = last ? free.filter((w) => w.app === last.app) : [];
        this.selected = free.find((w) => w.id === (this.selected?.id ?? this.config.current))
          ?? (last && free.find((w) => w.app === last.app && w.title === last.title))
          ?? (sameApp.length === 1 ? sameApp[0] : null);
        if (first) {
          this.restored = Boolean(this.selected && !this.config.current);
          this.pinned = this.selected?.id ?? 0;
        }
        // The window preselected on opening stays first; the rest keep a
        // stable order, so cards don't move under the pointer between refreshes.
        this.windows = rows.sort((a, b) => (b.id === this.pinned) - (a.id === this.pinned)
          || `${a.app} ${a.title}`.localeCompare(`${b.app} ${b.title}`));
        this.error = "";
      } catch (e) {
        if (this.closed) return;
        this.error = message(e);
        await this.removeThumbnails([folder]);
      } finally {
        this.loading = false;
        this.refreshing = false;
      }
      cx.notify();
      await this.removeThumbnails(this.generations.slice(0, -2));
    });
  }

  async removeThumbnails(folders) {
    if (folders.length === 0) return;
    this.generations = this.generations.filter((f) => !folders.includes(f));
    await exec("/bin/rm", ["-rf", ...folders.map((f) => `${appHome()}/${f}`)]);
  }

  async closePicker() {
    this.closed = true;
    await this.removeThumbnails(this.generations);
  }

  select(id, cx) {
    if (this.watchedElsewhere().has(id)) return;
    this.selected = this.windows.find((w) => w.id === id) ?? this.selected;
    this.restored = false;
    cx.notify();
  }

  // Windows other live copies of this mod are watching (their pane claims).
  watchedElsewhere() {
    const now = Date.now();
    return new Set(Object.values(shared(`${this.modName}:panes`) ?? {})
      .filter((c) => c.instance !== this.config.owner && c.target != null && now - c.at < 6000)
      .map((c) => c.target));
  }

  pick() {
    if (!this.selected) return;
    const { id, app, title } = this.selected;
    setShared(this.config.picksKey, { ...(shared(this.config.picksKey) ?? {}), [this.config.owner]: { window: { id, app, title } } });
    closeOverlay(this.config.overlay);
  }

  // MARK: settings dialog

  initSettings(cx) {
    cx.spawn(async () => {
      for (;;) {
        const command = await nextCommand();
        if (command === "delay-0" || command === "delay-250") {
          if (this.config.fixed == null) this.saveSettings({ delayMs: Number(command.slice(6)) });
        } else if (command.startsWith("fps-") && FPS_CHOICES.includes(Number(command.slice(4)))) {
          this.saveSettings({ fps: Number(command.slice(4)) });
        } else if (command === "close") closeOverlay(this.config.overlay);
      }
    });
  }

  // MARK: views

  button(id, label, enabled, onClick, active = false) {
    const c = theme();
    return div().id(id).px(12).py(7).rounded(6).flex_none()
      .bg(active ? c.solid : c.surface).text_color(active ? c.solid_foreground : enabled ? c.foreground : c.dim)
      .when(enabled, (el) => el.hover((s) => s.opacity(0.85)).on_click((_event, cx) => onClick(cx)))
      .child(label);
  }

  renderPicker() {
    const c = theme();
    const t = this.t;
    // Cards in as many columns of at least 200 px as fit (12 px: scrollbar).
    const gap = 10;
    const inner = this.size.width - 32 - 12;
    const columns = Math.max(1, Math.floor((inner + gap) / (200 + gap)));
    const cardWidth = Math.floor((inner - gap * (columns - 1)) / columns);
    return v_flex().id("picker").size_full().p(16).gap(10).bg(c.popover).text_color(c.foreground).text_size(13)
      .on_size_change((size, cx) => { this.size = size; cx.notify(); })
      .child(div().font_semibold().text_size(15).child(t.chooseTitle))
      .when(Boolean(this.error), (el) => el.child(div().text_color(c.blocked).child(this.error)))
      .when(this.restored, (el) => el.child(div().text_color(c.muted).child(t.restored)))
      .child(div().id("window-list").flex_1().min_h(0).overflow_y_scrollbar()
        .when(this.loading, (el) => el.child(div().text_color(c.muted).child(t.loadingWindows)))
        .when(!this.loading && this.windows.length === 0, (el) => el.child(div().text_color(c.muted).child(t.noWindows)))
        .child(h_flex().flex_wrap().gap(gap).children(this.windows.map((w) => this.windowCard(w, cardWidth)))))
      .child(h_flex().gap(8).justify_end()
        .child(this.button("cancel", t.cancel, true, () => closeOverlay(this.config.overlay)))
        .child(this.button("pick", t.start, Boolean(this.selected), () => this.pick(), Boolean(this.selected))));
  }

  // One window: its latest thumbnail, app and title. Double-click starts.
  windowCard(w, width) {
    const c = theme();
    const t = this.t;
    const taken = this.watchedElsewhere().has(w.id);
    const selected = w.id === this.selected?.id;
    const boxWidth = width - 16; // 6 px padding and 2 px border on each side
    const boxHeight = Math.round(boxWidth * 0.625);
    const ratio = w.width / Math.max(1, w.height);
    const imageWidth = Math.min(boxWidth, boxHeight * ratio);
    const imageHeight = imageWidth / ratio;
    const placed = (file) => image(file).absolute().left((boxWidth - imageWidth) / 2).top((boxHeight - imageHeight) / 2)
      .w(imageWidth).h(imageHeight);
    const file = this.thumbs.get(w.id);
    // The previous picture stays underneath: image() paints nothing while loading.
    const previous = this.previousThumbs.get(w.id);
    return v_flex().id(`select-${w.id}`).w(width).p(6).gap(6).rounded(8).border_2()
      .border_color(selected ? (c.accent ?? c.solid) : c.surface).bg(selected ? c.selected : c.surface)
      .when(taken, (el) => el.opacity(0.5))
      .when(!taken, (el) => el.hover((s) => s.bg(c.hover)).on_click((event, cx) => {
        this.select(w.id, cx);
        if (event.click_count >= 2) this.pick();
      }))
      .child(div().relative().w(boxWidth).h(boxHeight).rounded(4).overflow_hidden().bg(c.background)
        .when(Boolean(previous), (box) => box.child(placed(previous)))
        .when(Boolean(file), (box) => box.child(placed(file)))
        .when(!file && !previous, (box) => box.child(v_flex().size_full().items_center().justify_center()
          .text_color(c.muted).child(t.noPreview))))
      .child(div().min_w(0).truncate().font_semibold().child(w.app))
      .child(div().min_w(0).truncate().text_color(taken ? c.dim : c.muted)
        .child(`${w.title || t.untitled} · ${Math.round(w.width)}×${Math.round(w.height)}${taken ? t.watchedElsewhere : ""}`));
  }

  renderSettings() {
    const c = theme();
    const t = this.t;
    const fixed = this.config.fixed != null;
    const delay = this.config.fixed ?? this.settings.delayMs ?? 0;
    return v_flex().id("settings").size_full().p(16).gap(10).bg(c.popover).text_color(c.foreground).text_size(13)
      .child(div().font_semibold().text_size(15).child(t.fpsTitle))
      .child(h_flex().gap(8).children(FPS_CHOICES.map((n) =>
        this.button(`fps-${n}`, t.fpsChoice(n), true, () => this.saveSettings({ fps: n }), this.fps === n))))
      .child(div().text_color(c.muted).child(t.fpsBody))
      .child(div().font_semibold().text_size(15).child(t.delayTitle))
      .child(h_flex().gap(8)
        .child(this.button("delay-0", t.delayFast, !fixed, () => this.saveSettings({ delayMs: 0 }), delay === 0))
        .child(this.button("delay-250", t.delaySmooth, !fixed, () => this.saveSettings({ delayMs: 250 }), delay === 250)))
      .child(div().text_color(c.muted).child(fixed ? t.delayFixed : t.delayBody))
      .child(div().flex_1())
      .child(h_flex().justify_end().child(this.button("close", t.close, true, () => closeOverlay(this.config.overlay))));
  }

  setupPanel() {
    const c = theme();
    const t = this.t;
    const act = (id, label) => this.button(id, label, !this.busy, (cx) => this.action(id, cx));
    const panel = (title, body, buttons) => v_flex().gap(10).p(16).rounded(8).bg(c.surface).max_w(520)
      .child(div().font_semibold().child(title))
      .child(div().text_color(c.muted).child(body))
      .child(h_flex().gap(8).children(buttons));
    if (this.setup === "build" || this.setup === "building") {
      return panel(t.buildTitle, t.buildBody, [this.button("build", this.setup === "building" ? t.building : t.build,
        !this.busy, (cx) => this.action("build", cx))]);
    }
    if (this.setup === "permission") {
      return panel(t.permissionTitle, t.permissionBody,
        [act("request-permission", t.request), act("open-settings", t.openSettings), act("retry", t.retry)]);
    }
    if (this.error) return act("retry", t.retry);
    return div().text_color(c.muted).child(t.checking);
  }

  render(cx) {
    if (this.role === "picker") return this.renderPicker();
    if (this.role === "settings") return this.renderSettings();
    const c = theme();
    const t = this.t;
    const root = div().id("window-monitor").relative().size_full().min_w(0).min_h(0).overflow_hidden()
      .bg(c.background).text_color(c.foreground).text_size(13)
      .on_size_change((size, cx) => { this.size = size; cx.notify(); })
      .on_mouse_down("left", (_event, cx) => this.learnPane(cx));
    const centered = (child) => root.child(v_flex().size_full().p(16).gap(10).items_center().justify_center().child(child));
    if (this.setup !== "ready") {
      return centered(v_flex().gap(10).items_center()
        .when(Boolean(this.error), (el) => el.child(div().text_color(c.blocked).child(this.error)))
        .child(this.setupPanel()));
    }
    if (!this.terminal) {
      return centered(v_flex().gap(10).items_center()
        .child(div().text_color(this.error ? c.blocked : c.muted).child(this.error || t[this.messageKey]))
        .child(h_flex().gap(8)
          .child(this.button("choose", t.choose, !this.busy, (cx) => this.action("choose", cx), true))
          .child(this.button("settings", t.settings, true, (cx) => this.action("settings", cx)))));
    }
    // Watching: the image fills the pane; controls appear while the pointer is over it.
    root.on_hover((hovered, cx) => { this.hovered = hovered; cx.notify(); });
    if (this.file) {
      const ratio = (this.imageWidth ?? 1280) / (this.imageHeight ?? 800);
      const width = Math.max(40, Math.min(this.size.width, this.size.height * ratio));
      const height = width / ratio;
      root.child(h_flex().size_full().items_center().justify_center()
        .child(div().relative().w(width).h(height)
          .when(Boolean(this.previousFile), (layer) => layer.child(image(this.previousFile).absolute().inset_0().w(width).h(height)))
          .child(image(this.file).absolute().inset_0().w(width).h(height))));
    } else {
      root.child(v_flex().size_full().items_center().justify_center().child(div().text_color(c.muted).child(t.waiting)));
    }
    // Anything but "watching" stays visible without hovering: a frozen image
    // must not pass for a live one.
    const notice = this.error || (this.messageKey === "watching" ? "" : t[this.messageKey]);
    if (notice) {
      root.child(div().absolute().left(12).bottom(12).px(10).py(6).rounded(6).bg(c.popover)
        .text_color(this.error ? c.blocked : c.foreground).child(notice));
    }
    if (this.hovered) {
      root.child(h_flex().absolute().top(0).left(0).right(0).px(12).py(8).gap(8).items_center().bg(c.popover)
        .child(div().flex_1().min_w(0).truncate().child(`${this.selected.app} — ${this.selected.title || t.untitled}`))
        .child(this.button("stop", t.stop, !this.busy, (cx) => this.action("stop", cx)))
        .child(this.button("choose", t.change, !this.busy, (cx) => this.action("choose", cx)))
        .child(this.button("settings", t.settings, true, (cx) => this.action("settings", cx))));
    }
    return root;
  }
}
