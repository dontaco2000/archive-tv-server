/// Prevue-style guide channel (snapshot model, frame renderer, ffmpeg stream) and the weather channel.
library;

export 'src/layout.dart';
export 'src/renderer.dart'
    show FrameSource, GuideRenderer, WeatherPage, WeatherRenderer, genreColors, textWidth, weatherPages, weatherPhase, wrapText;
export 'src/snapshot.dart';
export 'src/stream.dart';
export 'src/weather.dart';
