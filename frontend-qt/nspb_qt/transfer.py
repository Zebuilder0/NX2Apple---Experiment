"""Windows: put games on an iPhone or iPad from the launcher's window.

One dialog serves three doors: Transfer to device on a game in the library, Install the launcher on a device in
Settings, and the question when a device without the launcher is plugged in (Model.newDeviceFound). The player picks
the device and the built games the app on it should hold, and the dialog follows the install (device_model.py
install_on_device with those titles): one progress bar for the whole run, the stage it is at and the log. Closed while
it runs, it becomes a small card in the window's bottom-right corner that keeps showing the progress; a click on the
card opens the dialog again.
"""
from __future__ import annotations

from PySide6.QtCore import QEvent, Qt, Signal
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from . import style
from .widgets import BigProgress, CardGroup, Spinner

#: How much of the bar each step takes. The game data (8 to 12 GB a game) is most of the time.
PREPARE_SHARE, SIGN_SHARE = 0.05, 0.15


def install_fraction(stages, info: dict | None, t) -> float:
    """How far an install is, for the bar: prepare and sign take the first fifth, the game data the rest, by bytes."""
    if info:
        return PREPARE_SHARE + SIGN_SHARE + (1 - PREPARE_SHARE - SIGN_SHARE) * min(1.0, info['done'] / info['total'])
    by_name = {s.name: s for s in stages}
    frac = 0.0
    for key, start, share in (('win.install.stage.prepare', 0.0, PREPARE_SHARE),
                              ('win.install.stage.sign', PREPARE_SHARE, SIGN_SHARE)):
        st = by_name.get(t(key))
        if st is None:
            continue
        if st.state == 'done':
            frac = start + share
        elif st.state == 'running':
            frac = start + share * max(0.0, min(100.0, float(st.percent or 0))) / 100
    data = by_name.get(t('win.install.stage.data'))
    if data is not None and data.state == 'done':
        frac = 1.0
    return frac


def finish_clock(seconds: float, now: float | None = None) -> str:
    """The clock time `seconds` from now in this PC's time zone and format (3:42 PM, 15:42), with the day when it
    is not today."""
    import time
    from PySide6.QtCore import QDateTime, QLocale
    end = QDateTime.fromSecsSinceEpoch(int((now if now is not None else time.time()) + seconds))
    loc = QLocale.system()
    clock = loc.toString(end.time(), QLocale.ShortFormat)
    if end.date() != QDateTime.currentDateTime().date():
        clock = loc.dayName(end.date().dayOfWeek(), QLocale.ShortFormat) + ' ' + clock
    return clock


def copy_lines(m, info: dict | None) -> tuple[str, str, str]:
    """The game data copy as three lines: which game (its number of all), the bytes and speed, the time left and
    when it should be done. Empty while no game data is copying."""
    if not info:
        return '', '', ''
    from .queue_model import format_duration
    t = m.t
    game = t('win.transfer.copying', info['game'], info['number'], info['count'])
    size = t('win.transfer.bytes', f"{info['done'] / 1e9:.1f}", f"{info['total'] / 1e9:.1f}")
    if info.get('rate'):
        size += ' · ' + t('win.transfer.speed', f"{info['rate'] / 1e6:.0f}")
    left = info.get('left')
    if left is None:
        eta = t('win.transfer.etaPending')
    else:
        eta = t('win.transfer.eta', format_duration(left, t), finish_clock(left, info.get('at')))
    return game, size, eta


class TransferDialog(QDialog):
    """Pick a device and the games for it, then follow the install. `preselect` are the title IDs to tick besides
    the games the app on the device holds already (None: the device's games, else every built game)."""

    minimized = Signal()         # closed while the install runs: the window shows the corner card
    progressed = Signal()        # the run moved (the corner card follows)
    done = Signal(bool, str)     # the run ended: ok, note

    def __init__(self, model, parent: QWidget | None = None, *, udid: str = '',
                 preselect: list[str] | None = None, new_device: bool = False) -> None:
        super().__init__(parent)
        self.m = model
        t = model.t
        self.new_device = new_device
        self.preselect = [p.upper() for p in preselect] if preselect is not None else None
        self.active = False
        self.finished_ok: bool | None = None
        self.stopped = False             # the run ended because the player stopped it (shown neither green nor red)
        self.note = ''
        self._checks: dict[str, QCheckBox] = {}
        self._udid = udid or model.install_udid
        self.setWindowTitle(t('win.transfer.window'))
        self.setMinimumSize(560, 520)
        self.setStyleSheet(style.STYLESHEET)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(28, 24, 28, 20)
        lay.setSpacing(14)

        self.head = QLabel('')
        self.head.setStyleSheet('font-size: 24px; font-weight: 800;')
        self.head.setWordWrap(True)
        lay.addWidget(self.head)
        self.sub = QLabel('')
        self.sub.setObjectName('pageNote')
        self.sub.setWordWrap(True)
        lay.addWidget(self.sub)

        # the device
        self.dev_group = CardGroup(title=t('dev.target'))
        r = QWidget()
        rl = QHBoxLayout(r)
        rl.setContentsMargins(18, 10, 18, 10)
        rl.setSpacing(10)
        self.dev_combo = QComboBox()
        self.dev_combo.setObjectName('launcherDropdown')
        self.dev_combo.currentIndexChanged.connect(self._on_device_changed)
        rl.addWidget(self.dev_combo, 1)
        self.refresh_btn = QPushButton(t('dev.refresh'))
        self.refresh_btn.clicked.connect(model.refresh_devices)
        rl.addWidget(self.refresh_btn)
        self.dev_group.add_row(r)
        # what the device's GPU plays: an older one (before the A17 Pro and the M1) needs games built with Older devices
        self.gpu_note = QLabel('')
        self.gpu_note.setObjectName('muted')
        self.gpu_note.setWordWrap(True)
        self.gpu_note.setContentsMargins(18, 0, 18, 10)
        self.dev_group.add_row(self.gpu_note)
        lay.addWidget(self.dev_group)

        # the games
        self.games_group = CardGroup(title=t('win.transfer.games'))
        self.games_host = QWidget()
        self.games_col = QVBoxLayout(self.games_host)
        self.games_col.setContentsMargins(18, 8, 18, 8)
        self.games_col.setSpacing(6)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setWidget(self.games_host)
        scroll.setMinimumHeight(120)
        self.games_group.add_row(scroll)
        lay.addWidget(self.games_group, 1)

        self.hint = QLabel('')
        self.hint.setObjectName('muted')
        self.hint.setWordWrap(True)
        lay.addWidget(self.hint)

        # the run
        self.run_box = QWidget()
        rb = QVBoxLayout(self.run_box)
        rb.setContentsMargins(0, 0, 0, 0)
        rb.setSpacing(10)
        self.progress = BigProgress()
        rb.addWidget(self.progress, 0)
        # the game data copy: the game it is on, the bytes and speed, the time left and the clock time it ends
        self.copy_box = QWidget()
        cb = QVBoxLayout(self.copy_box)
        cb.setContentsMargins(0, 2, 0, 0)
        cb.setSpacing(3)
        self.copy_game = QLabel('')
        self.copy_game.setObjectName('rowTitle')
        self.copy_game.setWordWrap(True)
        self.copy_bytes = QLabel('')
        self.copy_bytes.setObjectName('muted')
        self.copy_eta = QLabel('')
        self.copy_eta.setStyleSheet(f'color: {style.ACCENT}; font-weight: 600;')
        self.copy_eta.setWordWrap(True)
        for w in (self.copy_game, self.copy_bytes, self.copy_eta):
            cb.addWidget(w)
        self.copy_box.hide()
        rb.addWidget(self.copy_box, 0)
        self.log_btn = QPushButton('›  ' + t('build.log'))
        self.log_btn.setObjectName('ghost')
        self.log_btn.clicked.connect(self._toggle_log)
        rb.addWidget(self.log_btn, 0, Qt.AlignLeft)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMinimumHeight(140)
        self.log.hide()
        rb.addWidget(self.log, 1)
        rb.addStretch(1)
        self.run_box.hide()
        lay.addWidget(self.run_box, 1)

        foot = QHBoxLayout()
        self.close_btn = QPushButton(t('win.transfer.notNow') if new_device else t('win.transfer.cancel'))
        self.close_btn.setObjectName('ghost')
        self.close_btn.clicked.connect(self.close)
        foot.addWidget(self.close_btn)
        foot.addStretch(1)
        self.stop_btn = QPushButton(t('btn.stop'))
        self.stop_btn.setObjectName('danger')
        self.stop_btn.clicked.connect(model.cancel_install)
        self.stop_btn.hide()
        foot.addWidget(self.stop_btn)
        self.go_btn = QPushButton('')
        self.go_btn.setObjectName('creamPill')
        self.go_btn.setMinimumWidth(170)
        self.go_btn.clicked.connect(self._start)
        foot.addWidget(self.go_btn)
        lay.addLayout(foot)

        # Bound methods only: PySide disconnects them when this dialog is destroyed (the window deletes the old one
        # when it opens a new one). A lambda has no receiver, stays connected to the model for the whole session and
        # then runs on deleted widgets ("Internal C++ object already deleted").
        model.devicesChanged.connect(self._fill_devices)
        model.depsChanged.connect(self._refresh)
        model.runningChanged.connect(self._on_running)
        model.stagesChanged.connect(self._on_stages)
        model.logAppended.connect(self._on_log)
        model.finished.connect(self._on_finished)
        self._fill_devices()

    def _on_running(self, _running: bool) -> None:
        self._refresh()

    # ---------------------------------------------------------------- choosing

    @property
    def udid(self) -> str:
        return self._udid

    def _wired_devices(self) -> list:
        return [d for d in self.m.devices if d.wired]

    def _fill_devices(self) -> None:
        if self.active:
            return
        devs = self._wired_devices()
        self.dev_combo.blockSignals(True)
        self.dev_combo.clear()
        for d in devs:
            self.dev_combo.addItem(self.m.device_label(d), d.udid)
        if not devs:
            self.dev_combo.addItem(self.m.t('dev.none'), '')
        idx = next((i for i, d in enumerate(devs) if d.udid == self._udid), 0)
        self.dev_combo.setCurrentIndex(idx)
        self.dev_combo.blockSignals(False)
        self._udid = devs[idx].udid if devs else ''
        self._fill_games()

    def _on_device_changed(self, idx: int) -> None:
        self._udid = str(self.dev_combo.itemData(idx) or '')
        self._fill_games()

    def _fill_games(self) -> None:
        t = self.m.t
        while self.games_col.count():
            it = self.games_col.takeAt(0)
            old = it.widget()
            if old is not None:      # off the screen at once: deleteLater alone drew it over the new row for a frame
                old.hide()
                old.setParent(None)
                old.deleteLater()
        self._checks = {}
        games = self.m.built_games()
        on_device = set(self.m.device_titles(self._udid)) if self._udid else set()
        older = self.m.device_gpu(self._udid) == 'older' if self._udid else False
        plays = {g.title_id.upper(): self.m.game_plays_on_older(g.title_id) for g in games}
        if self.preselect is None:
            ticked = on_device or {g.title_id.upper() for g in games}
        else:
            ticked = on_device | set(self.preselect)
        if older:      # a game built for newer devices only would stop at its start here: not ticked unless it is there
            ticked = {tid for tid in ticked if plays.get(tid, True) or tid in on_device}
        self._plays = plays
        self._older = older
        for g in games:
            tid = g.title_id.upper()
            row = QWidget()
            rl = QHBoxLayout(row)
            rl.setContentsMargins(0, 2, 0, 2)
            rl.setSpacing(10)
            cb = QCheckBox(g.name or tid)
            cb.setChecked(tid in ticked)
            cb.toggled.connect(self._on_game_toggled)
            rl.addWidget(cb, 1)
            ready = QLabel(t('win.transfer.tagAll') if plays.get(tid) else t('win.transfer.tagNewer'))
            ready.setStyleSheet(f'color: {style.GREEN if plays.get(tid) else style.AMBER}; font-size: 12px;')
            rl.addWidget(ready)
            tag = QLabel(t('win.transfer.onDevice') if tid in on_device else tid)
            tag.setObjectName('muted' if tid in on_device else 'mono')
            rl.addWidget(tag)
            self.games_col.addWidget(row)
            self._checks[tid] = cb
        if not games:
            empty = QLabel(t('win.transfer.noGames'))
            empty.setObjectName('muted')
            empty.setWordWrap(True)
            self.games_col.addWidget(empty)
        self.games_col.addStretch(1)
        self._refresh()

    def _on_game_toggled(self, _on: bool) -> None:
        self._refresh()

    def titles(self) -> list[str]:
        return sorted(tid for tid, cb in self._checks.items() if cb.isChecked())

    def _refresh(self) -> None:
        t = self.m.t
        dev = self.m.device_by_udid(self._udid) if self._udid else None
        name = (dev.name if dev else '') or t('win.transfer.aDevice')
        has_app = bool(self.m.device_titles(self._udid)) if self._udid else False
        if self.new_device:
            self.head.setText(t('win.transfer.newTitle', name))
            self.sub.setText(t('win.transfer.newNote'))
        else:
            self.head.setText(t('win.transfer.title'))
            self.sub.setText(t('win.transfer.note'))
        if self.active or self.finished_ok is not None:
            return
        self.go_btn.setText(t('win.transfer.update' if has_app else 'win.transfer.install'))
        on_device = set(self.m.device_titles(self._udid)) if self._udid else set()
        removed = sorted(on_device - set(self.titles()))
        gpu = self.m.device_gpu(self._udid) if self._udid else 'unknown'
        self.gpu_note.setVisible(gpu != 'unknown')
        self.gpu_note.setText(t('win.transfer.gpuOlder', name) if gpu == 'older' else t('win.transfer.gpuNew', name))
        self.gpu_note.setStyleSheet(f'color: {style.AMBER};' if gpu == 'older' else '')
        names = {g.title_id.upper(): g.name for g in self.m.built_games()}
        stuck = [names.get(tid, tid) for tid in self.titles() if gpu == 'older' and not getattr(self, '_plays', {}).get(tid, True)]
        if not self.m.device_install_ready:
            why = t('win.install.needsSetup')
        elif not self._udid:
            why = t('win.transfer.plugIn')
        elif self.m.running:
            why = t('win.transfer.busy')
        elif not self.titles():
            why = t('win.transfer.pickOne')
        else:
            why = ''
        note = why or (t('win.transfer.removes', len(removed)) if removed else t('win.transfer.ready'))
        if not why and stuck:            # ticked anyway: it is said, before it is installed
            note = t('win.transfer.olderWarn', name, ', '.join(stuck)) + (' ' + note if removed else '')
        self.hint.setText(note)
        self.go_btn.setEnabled(not why)

    # ---------------------------------------------------------------- the run

    def _start(self) -> None:
        if self.active or not self.go_btn.isEnabled():
            return
        if self.finished_ok is not None:      # Close after a run
            self.accept()
            return
        titles = self.titles()
        self.active = True
        self.finished_ok = None
        self.log.clear()
        self.dev_group.setEnabled(False)
        self.games_group.hide()
        self.hint.hide()
        self.run_box.show()
        self.stop_btn.show()
        self.go_btn.hide()
        self.close_btn.setText(self.m.t('win.transfer.hide'))
        self.progress.set_progress(self.m.t('win.transfer.toast', self._device_name()), 0.0,
                                   self.m.t('win.install.stage.prepare'), busy=True)
        self.m.set_install_device(self._udid)
        if not self.m.transfer_games(self._udid, titles):
            # another run started in the meantime (an automatic update): back to choosing, with the reason
            self.active = False
            self.dev_group.setEnabled(True)
            self.games_group.show()
            self.hint.show()
            self.run_box.hide()
            self.stop_btn.hide()
            self.go_btn.show()
            self.close_btn.setText(self.m.t('win.transfer.notNow') if self.new_device else self.m.t('win.transfer.cancel'))
            self._refresh()

    def stage_text(self) -> tuple[str, float, bool]:
        """What runs now, how far the whole run is, and whether it failed (for the bar and the corner card)."""
        stages = list(self.m.stages)
        running = next((s for s in stages if s.state == 'running'), None)
        failed = next((s for s in stages if s.state == 'failed'), None)
        frac = 1.0 if self.finished_ok else install_fraction(stages, getattr(self.m, 'transfer_info', None), self.m.t)
        if self.finished_ok is not None:
            return (self.note or self.m.t('msg.done')), frac, not self.finished_ok and not self.stopped
        cur = running or failed or (stages[-1] if stages else None)
        if cur is None:
            return self.m.t('win.install.stage.prepare'), frac, False
        return (cur.name + (' · ' + cur.detail if cur.detail else '')), frac, cur.state == 'failed'

    def _device_name(self) -> str:
        dev = self.m.device_by_udid(self._udid) if self._udid else None
        return (dev.name if dev else '') or self.m.t('win.transfer.aDevice')

    def _on_stages(self) -> None:
        if not self.active:
            return
        text, frac, failed = self.stage_text()
        self.progress.set_progress(self.m.t('win.transfer.toast', self._device_name()), frac, text, failed, busy=True)
        game, size, eta = copy_lines(self.m, getattr(self.m, 'transfer_info', None))
        self.copy_box.setVisible(bool(game))
        self.copy_game.setText(game)
        self.copy_bytes.setText(size)
        self.copy_eta.setText(eta)
        self.progressed.emit()

    def _on_log(self, s: str) -> None:
        if not self.active:
            return
        c = self.log.textCursor()
        c.movePosition(c.MoveOperation.End)
        c.insertText(s)
        self.log.setTextCursor(c)
        self.log.ensureCursorVisible()

    def _on_finished(self, ok: bool, note: str) -> None:
        if not self.active:
            return
        self.active = False
        self.finished_ok = ok
        self.stopped = bool(getattr(self.m, 'run_stopped', False))
        self.note = note
        self.stop_btn.hide()
        self.close_btn.hide()
        self.go_btn.show()
        self.go_btn.setEnabled(True)
        self.go_btn.setText(self.m.t('win.transfer.close'))
        self.progress.set_progress(self.title_text(),
                                   1.0 if ok else install_fraction(self.m.stages, None, self.m.t), note,
                                   not ok and not self.stopped)
        self.copy_box.hide()
        if not ok and not self.stopped:
            self.log.show()
            self.log_btn.setText('⌄  ' + self.m.t('build.log'))
        self.progressed.emit()
        self.done.emit(ok, note)

    def title_text(self) -> str:
        """The finished run's heading: installed, stopped, or failed."""
        if self.finished_ok:
            return self.m.t('win.transfer.doneTitle')
        return self.m.t('msg.stopped') if self.stopped else self.m.t('win.transfer.failedTitle')

    def _toggle_log(self) -> None:
        self.log.setVisible(not self.log.isVisible())
        self.log_btn.setText(('⌄  ' if self.log.isVisible() else '›  ') + self.m.t('build.log'))

    def closeEvent(self, event) -> None:
        if self.active:
            event.ignore()
            self.hide()
            self.minimized.emit()
            return
        super().closeEvent(event)

    def reject(self) -> None:
        if self.active:
            self.hide()
            self.minimized.emit()
            return
        super().reject()


class TransferToast(QFrame):
    """The corner card of a running transfer: where it is and how far, a click opens the dialog again."""

    def __init__(self, parent: QWidget) -> None:
        super().__init__(parent)
        self.setObjectName('transferToast')
        self.setStyleSheet(f'QFrame#transferToast {{ background: #1c1c1f; border: 1px solid {style.BORDER}; '
                           f'border-radius: 14px; }}')
        self.setFixedWidth(340)
        self.setCursor(Qt.PointingHandCursor)
        self.dialog: TransferDialog | None = None
        col = QVBoxLayout(self)
        col.setContentsMargins(16, 12, 12, 14)
        col.setSpacing(6)
        top = QHBoxLayout()
        self.spinner = Spinner(14)
        top.addWidget(self.spinner)
        self.title = QLabel('')
        self.title.setStyleSheet('font-weight: 700; background: transparent;')
        top.addWidget(self.title, 1)
        self.pct = QLabel('')
        self.pct.setStyleSheet(f'font-weight: 700; color: {style.ACCENT}; background: transparent;')
        top.addWidget(self.pct)
        self.x_btn = QPushButton('✕')
        self.x_btn.setObjectName('ghost')
        self.x_btn.setFixedSize(26, 22)
        self.x_btn.clicked.connect(self.dismiss)
        top.addWidget(self.x_btn)
        col.addLayout(top)
        self.stage = QLabel('')
        self.stage.setObjectName('muted')
        self.stage.setWordWrap(True)
        col.addWidget(self.stage)
        self.bar = QProgressBar()
        self.bar.setObjectName('barProgress')
        self.bar.setRange(0, 1000)
        self.bar.setTextVisible(False)
        col.addWidget(self.bar)
        self.hide()
        parent.installEventFilter(self)

    def follow(self, dialog: TransferDialog) -> None:
        self.dialog = dialog
        dialog.progressed.connect(self.update_from_dialog)
        self.update_from_dialog()
        self.place()
        self.show()
        self.raise_()

    def update_from_dialog(self) -> None:
        d = self.dialog
        if d is None:
            return
        t = d.m.t
        dev = d.m.device_by_udid(d.udid)
        name = (dev.name if dev else '') or t('win.transfer.aDevice')
        text, frac, failed = d.stage_text()
        if d.finished_ok is None:
            self.title.setText(t('win.transfer.toast', name))
        else:
            self.title.setText(d.title_text())
        game, _size, eta = copy_lines(d.m, getattr(d.m, 'transfer_info', None)) if d.finished_ok is None else ('', '', '')
        self.stage.setText(f'{game}\n{eta}' if game else text)
        self.pct.setText(f'{int(frac * 100)}%')
        self.pct.setStyleSheet(f'font-weight: 700; color: {style.RED if failed else style.ACCENT}; background: transparent;')
        self.bar.setValue(int(frac * 1000))
        self.x_btn.setVisible(d.finished_ok is not None)
        self.spinner.set_spinning(d.finished_ok is None)

    def place(self) -> None:
        p = self.parentWidget()
        if p is None:
            return
        self.adjustSize()
        bottom = 44 + 16       # above the activity bar
        self.move(p.width() - self.width() - 20, p.height() - self.height() - bottom)

    def eventFilter(self, obj, event) -> bool:
        if obj is self.parentWidget() and event.type() == QEvent.Resize and self.isVisible():
            self.place()
        return False

    def mouseReleaseEvent(self, event) -> None:
        if event.button() == Qt.LeftButton and self.dialog is not None:
            self.dialog.show()
            self.dialog.raise_()
            self.dialog.activateWindow()
            if self.dialog.finished_ok is not None:
                self.dismiss()
        super().mouseReleaseEvent(event)

    def dismiss(self) -> None:
        self.hide()
