#!/usr/bin/env python3
"""
Swap - System tray app to switch between
Claude Code settings.json profiles.
"""

import json
import os
import signal
import subprocess
import sys
from pathlib import Path

import gi

# Try Ayatana first (Ubuntu 22.04+), fall back to legacy AppIndicator3
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator3
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib

# ── Constants ────────────────────────────────────────────────────────
CONFIG_FILE = Path.home() / ".claude" / "swap.json"
POLL_INTERVAL = 3  # seconds

DEFAULT_ICON_PATH = str(Path(__file__).parent / "assets" / "swap-icon.svg")
_HICOLOR_ICON = Path.home() / ".local/share/icons/hicolor/scalable/apps/swap.svg"
DEFAULT_ICON = "swap" if _HICOLOR_ICON.exists() else DEFAULT_ICON_PATH


# ── Helpers ──────────────────────────────────────────────────────────

def _safe_write(path: Path, data: str):
    """Write data to a file atomically using tmp + rename."""
    tmp = path.with_suffix(".tmp")
    tmp.write_text(data)
    os.replace(str(tmp), str(path))
    os.chmod(str(path), 0o600)


def load_config() -> dict | None:
    """Load and validate the config file. Returns None on error."""
    if not CONFIG_FILE.exists():
        return None
    try:
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
        if "target" not in cfg or "profiles" not in cfg:
            return None
        if not isinstance(cfg["profiles"], dict) or not cfg["profiles"]:
            return None
        return cfg
    except Exception:
        return None


def detect_active_profile(cfg: dict) -> str | None:
    """Compare the target file content against each profile to find the active one."""
    target = Path(cfg["target"]).expanduser()
    if not target.exists():
        return None
    try:
        with open(target) as f:
            current = json.load(f)
    except Exception:
        return None
    for name, content in cfg["profiles"].items():
        if current == content:
            return name
    return None


def apply_profile(cfg: dict, profile_name: str):
    """Write the selected profile content to the target file."""
    target = Path(cfg["target"]).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    content = json.dumps(cfg["profiles"][profile_name], indent=2) + "\n"
    _safe_write(target, content)
    # Desktop notification
    try:
        subprocess.Popen(
            ["notify-send", "-i", DEFAULT_ICON_PATH,
             "Swap", f"Switched to: {profile_name}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        pass


def seed_config():
    """Create an example config if none exists."""
    if CONFIG_FILE.exists():
        return
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    example = {
        "target": "~/.claude/settings.json",
        "profiles": {
            "Claude": {
                "model": "opus",
                "permissions": {
                    "allow": ["Bash(*)","Read(*)","Write(*)","Edit(*)","Glob(*)","Grep(*)","WebFetch(*)","WebSearch(*)"],
                    "deny": []
                }
            },
            "GLM": {
                "model": "opus",
                "permissions": {
                    "allow": ["Bash(*)","Read(*)","Write(*)","Edit(*)","Glob(*)","Grep(*)"],
                    "deny": ["WebFetch(*)","WebSearch(*)"]
                }
            },
            "Empresa": {
                "model": "sonnet",
                "permissions": {
                    "allow": ["Read(*)","Glob(*)","Grep(*)"],
                    "deny": ["Bash(*)","Write(*)","Edit(*)","WebFetch(*)","WebSearch(*)"]
                }
            },
        },
    }
    _safe_write(CONFIG_FILE, json.dumps(example, indent=2) + "\n")


# ── Tray Class ───────────────────────────────────────────────────────

class SwapTray:
    def __init__(self):
        self.indicator = AppIndicator3.Indicator.new(
            "swap",
            DEFAULT_ICON,
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_title("Swap")
        self._config_mtime = 0.0
        self._config = None
        self._build_menu()
        GLib.timeout_add_seconds(POLL_INTERVAL, self._poll)

    def _build_menu(self):
        self._config = load_config()
        menu = Gtk.Menu()

        if self._config is None:
            item = Gtk.MenuItem(label="Config error - check ~/.claude/swap.json")
            item.set_sensitive(False)
            menu.append(item)
            menu.append(Gtk.SeparatorMenuItem())
            self._append_footer(menu)
            menu.show_all()
            self.indicator.set_menu(menu)
            return

        # Header: target file
        target_name = Path(self._config["target"]).name
        header = Gtk.MenuItem(label=f"Target: {target_name}")
        header.set_sensitive(False)
        menu.append(header)
        menu.append(Gtk.SeparatorMenuItem())

        # Detect active profile
        active = detect_active_profile(self._config)

        # Radio items for each profile
        group = []
        for name in self._config["profiles"]:
            if not group:
                item = Gtk.RadioMenuItem.new_with_label([], name)
            else:
                item = Gtk.RadioMenuItem.new_with_label(group, name)
            group = item.get_group()
            if name == active:
                item.set_active(True)
            else:
                item.set_active(False)
            item.connect("toggled", self._on_profile_toggled, name)
            menu.append(item)

        menu.append(Gtk.SeparatorMenuItem())
        self._append_footer(menu)
        menu.show_all()
        self.indicator.set_menu(menu)

    def _append_footer(self, menu: Gtk.Menu):
        # Edit Config
        edit_item = Gtk.MenuItem(label="Edit Config...")
        edit_item.connect("activate", self._on_edit_config)
        menu.append(edit_item)

        # Reload
        reload_item = Gtk.MenuItem(label="Reload Config")
        reload_item.connect("activate", lambda _: self._build_menu())
        menu.append(reload_item)

        menu.append(Gtk.SeparatorMenuItem())

        # Quit
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda _: Gtk.main_quit())
        menu.append(quit_item)

    def _on_profile_toggled(self, widget, profile_name):
        if not widget.get_active():
            return
        if self._config is None:
            return
        apply_profile(self._config, profile_name)

    def _on_edit_config(self, _widget):
        try:
            subprocess.Popen(
                ["xdg-open", str(CONFIG_FILE)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            pass

    def _poll(self) -> bool:
        try:
            mtime = CONFIG_FILE.stat().st_mtime
        except OSError:
            return True
        if mtime != self._config_mtime:
            self._config_mtime = mtime
            self._build_menu()
        return True


# ── Main ─────────────────────────────────────────────────────────────

def main():
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    seed_config()

    if "--seed-only" in sys.argv:
        return

    signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
    signal.signal(signal.SIGINT, lambda *_: Gtk.main_quit())

    SwapTray()
    Gtk.main()


if __name__ == "__main__":
    main()
