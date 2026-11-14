import 'package:archive_tv_core/archive_tv_core.dart';

/// What the guides show for one programme (XMLTV and the guide channel).
typedef TitleInfo = ({String title, String? subTitle, String? description, int? season, int? episode});

final _sxe = RegExp(r'\bS(\d{1,2})\s*E(\d{1,3})\b', caseSensitive: false);

/// Archive item titles/descriptions (core `ItemInfoStore`, `<data>/item_info.json`); null = file titles only.
ItemInfoStore? itemInfos;

/// THE hook for guide titles: the XMLTV and the guide channel both call only this. Core `programmeInfo`
/// (the app's titles: item title for date/number/generic file names, sub-title, item description) plus an
/// SxxEyy parse for Plex's episode numbers. [block]: a guide block ("X Marathon", "More Trailers"): its
/// title is the block's, so no item lookup (the first item's description would be wrong for the block).
TitleInfo programmeTitleInfo(Entry e, {bool block = false}) {
  final p = programmeInfo(e, block ? null : itemInfos?[e.itemId]);
  final m = _sxe.firstMatch('${p.title} ${p.subTitle ?? ''}');
  return (
    title: p.title,
    subTitle: p.subTitle,
    description: block ? null : p.description,
    season: m == null ? null : int.parse(m[1]!),
    episode: m == null ? null : int.parse(m[2]!),
  );
}
