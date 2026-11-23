# X4 three-monitor cockpit and launch manager

Tools for X4: Foundations 9.00 on Windows:

- **[x4cockpit3/](x4cockpit3/)** – three-monitor cockpit: one borderless game window across side | centre | side
  monitors, using a small launcher and an in-process window hook (our own implementation), plus the config switcher
  and monitor-arrangement check.
- **[x4switch/](x4switch/)** – a small launch manager (X4Switch.exe) to choose how the game starts: the
  three-monitor cockpit, or the normal single-monitor game with the X4 Companion browser dashboard
  (github.com/makosdDavid/xmod). Each tool also works on its own.

The two folders are expected side by side (the manager finds `x4cockpit3` next to itself; settings can override it).
Build instructions and limits are in each folder's README.

This is an unofficial fan project. It is not affiliated with, endorsed, or supported by Egosoft.
Egosoft assumes no technical support or liability (e.g., for corrupted save games). Use at your own risk.
All names, trademarks, and content related to X4: Foundations are the property of Egosoft or their respective owners.
