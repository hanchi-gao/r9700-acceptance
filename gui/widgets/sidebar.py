"""Left navigation sidebar."""
from PyQt6.QtWidgets import QWidget, QVBoxLayout, QPushButton, QLabel
from PyQt6.QtCore import pyqtSignal, Qt


class SideBar(QWidget):
    page_changed = pyqtSignal(int)

    def __init__(self):
        super().__init__()
        self.setFixedWidth(160)
        self.setStyleSheet("background:#0f1628;")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 16, 0, 16)
        lay.setSpacing(4)

        title = QLabel("R9700")
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        title.setStyleSheet("color:#00d4ff; font-size:20px; font-weight:bold; padding:8px;")
        lay.addWidget(title)

        subtitle = QLabel("BURN-IN")
        subtitle.setAlignment(Qt.AlignmentFlag.AlignCenter)
        subtitle.setStyleSheet("color:#888; font-size:11px; letter-spacing:3px; padding-bottom:16px;")
        lay.addWidget(subtitle)

        self._buttons = []
        for i, (icon, label) in enumerate([
            ("⚡", "STABILITY\nTEST"),
            ("\U0001f4ca", "MONITORING"),
            ("\U0001f916", "AI MODEL"),
            ("⚙", "SETTINGS"),
        ]):
            btn = QPushButton(f"{icon}  {label}")
            btn.setCheckable(True)
            btn.setStyleSheet("""
                QPushButton {
                    color: #aaa; background: transparent; border: none;
                    font-size: 13px; padding: 16px 12px; text-align: left;
                }
                QPushButton:checked {
                    color: #00d4ff; background: #1a2744; border-left: 3px solid #00d4ff;
                }
                QPushButton:hover { background: #1a2744; }
            """)
            btn.clicked.connect(lambda checked, idx=i: self._on_click(idx))
            self._buttons.append(btn)
            lay.addWidget(btn)

        lay.addStretch()
        self._buttons[0].setChecked(True)

    def _on_click(self, idx):
        for i, btn in enumerate(self._buttons):
            btn.setChecked(i == idx)
        self.page_changed.emit(idx)
