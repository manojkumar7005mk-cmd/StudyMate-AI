import 'package:flutter/material.dart';

class AppTab {
  const AppTab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.page,
  });
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget page;
}

/// Phone: bottom tab bar like Instagram. Wide screens (Windows/Linux): side rail.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.tabs});
  final List<AppTab> tabs;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    // IndexedStack keeps each tab alive, so the chat and the planner keep their state.
    final stack = IndexedStack(index: _index, children: [for (final t in widget.tabs) t.page]);

    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              for (final t in widget.tabs)
                NavigationRailDestination(
                  icon: Icon(t.icon),
                  selectedIcon: Icon(t.selectedIcon),
                  label: Text(t.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: stack),
        ]),
      );
    }

    return Scaffold(
      body: stack,
      bottomNavigationBar: NavigationBar(
        height: 68,
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final t in widget.tabs)
            NavigationDestination(
              icon: Icon(t.icon),
              selectedIcon: Icon(t.selectedIcon),
              label: t.label,
            ),
        ],
      ),
    );
  }
}
