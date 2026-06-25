#!/usr/bin/env python3
"""R9700 Burn-in Dashboard — OCCT-style desktop GUI."""
import sys
import os

from PyQt6.QtWidgets import QApplication, QMainWindow, QHBoxLayout, QVBoxLayout, QWidget, QStackedWidget
from PyQt6.QtGui import QPalette, QColor
from PyQt6.QtCore import Qt

sys.path.insert(0, os.path.dirname(__file__))

from sensors import SensorThread
from widgets.topbar import TopBar
from widgets.sidebar import SideBar
from pages.stress_page import StressPage
from pages.monitor_page import MonitorPage
from pages.llm_page import LlmPage


def apply_dark_theme(app):
    p = QPalette()
    p.setColor(QPalette.ColorRole.Window, QColor("#1a1a2e"))
    p.setColor(QPalette.ColorRole.WindowText, QColor("#e0e0e0"))
    p.setColor(QPalette.ColorRole.Base, QColor("#16213e"))
    p.setColor(QPalette.ColorRole.AlternateBase, QColor("#1c2a4a"))
    p.setColor(QPalette.ColorRole.Text, QColor("#e0e0e0"))
    p.setColor(QPalette.ColorRole.Button, QColor("#1c2a4a"))
    p.setColor(QPalette.ColorRole.ButtonText, QColor("#e0e0e0"))
    p.setColor(QPalette.ColorRole.Highlight, QColor("#00d4ff"))
    p.setColor(QPalette.ColorRole.HighlightedText, QColor("#111"))
    app.setPalette(p)
    app.setStyleSheet("""
        QToolTip { background:#1c2a4a; color:#e0e0e0; border:1px solid #00d4ff; }
        QScrollBar:vertical { background:#1a1a2e; width:8px; }
        QScrollBar::handle:vertical { background:#444; border-radius:4px; }
        QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height:0; }
    """)


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("R9700 Burn-in Dashboard")
        self.resize(1400, 850)

        central = QWidget()
        self.setCentralWidget(central)
        root_layout = QVBoxLayout(central)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        self.topbar = TopBar()
        root_layout.addWidget(self.topbar)

        body = QWidget()
        body_layout = QHBoxLayout(body)
        body_layout.setContentsMargins(0, 0, 0, 0)
        body_layout.setSpacing(0)

        self.sidebar = SideBar()
        body_layout.addWidget(self.sidebar)

        self.stack = QStackedWidget()
        self.stress_page = StressPage()
        self.monitor_page = MonitorPage()
        self.llm_page = LlmPage()
        self.stack.addWidget(self.stress_page)
        self.stack.addWidget(self.monitor_page)
        self.stack.addWidget(self.llm_page)
        body_layout.addWidget(self.stack)

        root_layout.addWidget(body)

        self.sidebar.page_changed.connect(self.stack.setCurrentIndex)

        self.sensor_thread = SensorThread(interval_ms=2000)
        self.sensor_thread.data_ready.connect(self.topbar.update_data)
        self.sensor_thread.data_ready.connect(self.monitor_page.on_sensor_data)
        self.sensor_thread.data_ready.connect(self.stress_page.on_sensor_data)
        self.sensor_thread.start()

    def closeEvent(self, event):
        self.stress_page.force_stop()
        self.sensor_thread.stop()
        event.accept()


def main():
    app = QApplication(sys.argv)
    apply_dark_theme(app)
    win = MainWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
