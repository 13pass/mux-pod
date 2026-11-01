import 'package:flutter/material.dart';

import '../../../l10n/l10n_ext.dart';
import '../../../theme/design_colors.dart';

/// ホーム画面のボトムナビゲーションバー。
///
/// home 画面内部専用の表示部品。タブ状態は外部（[currentTab] / [onSelectTab]）
/// から受け取り、自身では保持しない（状態所有権は中立
/// `lib/navigation/current_tab_provider.dart` の [CurrentTabNotifier]）。
///
/// 6タブ（Servers / Keys / Dashboard / Notify / Settings / Agent）は
/// 均等幅 [Expanded] で並べる。かつての「中央からはみ出す Dashboard 円形
/// ボタン」は 5 タブ時代のデザインで、6 タブでは隣接アイテムに重なって
/// タップを横取りするため廃止した。
class HomeBottomNavBar extends StatelessWidget {
  const HomeBottomNavBar({
    super.key,
    required this.currentTab,
    required this.onSelectTab,
  });

  /// 現在のタブインデックス（0=Servers, 1=Keys, 2=Dashboard, 3=Notify,
  /// 4=Settings, 5=Agent）。
  final int currentTab;

  /// タブ選択時のコールバック（親がタブ状態へ反映する）。
  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? DesignColors.backgroundDark.withValues(alpha: 0.9)
            : DesignColors.footerBackgroundLight.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(
            color: isDark ? DesignColors.surfaceDark : DesignColors.borderLight,
          ),
        ),
      ),
      child: SafeArea(
        child: SizedBox(
          height: 72,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _buildNavItem(
                context,
                index: 0,
                icon: Icons.dns,
                label: context.l10n.homeServers,
                isSelected: currentTab == 0,
              ),
              _buildNavItem(
                context,
                index: 1,
                icon: Icons.key,
                label: context.l10n.homeKeys,
                isSelected: currentTab == 1,
              ),
              _buildNavItem(
                context,
                index: 2,
                icon: Icons.terminal,
                label: context.l10n.homeDashboard,
                isSelected: currentTab == 2,
              ),
              _buildNavItem(
                context,
                index: 3,
                icon: Icons.notifications_outlined,
                label: context.l10n.homeNotify,
                isSelected: currentTab == 3,
              ),
              _buildNavItem(
                context,
                index: 4,
                icon: Icons.settings,
                label: context.l10n.homeSettings,
                isSelected: currentTab == 4,
              ),
              _buildNavItem(
                context,
                key: const Key('home_nav_agent'),
                index: 5,
                icon: Icons.smart_toy_outlined,
                label: context.l10n.homeAgent,
                isSelected: currentTab == 5,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    Key? key,
    required int index,
    required IconData icon,
    required String label,
    required bool isSelected,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactiveColor = isDark
        ? DesignColors.textMuted
        : DesignColors.textMutedLight;
    return Expanded(
      key: key,
      child: GestureDetector(
        onTap: () => onSelectTab(index),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // アクティブインジケーター
              if (isSelected)
                Container(
                  width: 24,
                  height: 2,
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: DesignColors.primary,
                    borderRadius: BorderRadius.circular(1),
                    boxShadow: [
                      BoxShadow(
                        color: DesignColors.primary.withValues(alpha: 0.5),
                        blurRadius: 8,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                )
              else
                const SizedBox(height: 8),
              Icon(
                icon,
                size: 22,
                color: isSelected ? DesignColors.primary : inactiveColor,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.3,
                  color: isSelected ? DesignColors.primary : inactiveColor,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
