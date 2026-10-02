/// Presentation only; financial amounts and their exact labels are unchanged.
/// A lower bound keeps extreme ratios readable and avoids treating the native
/// bridge's saturated i64 percentage as an exact ratio.
String progressPercentLabel(int percent) =>
    percent > 1000000 ? '>1,000,000%' : '$percent%';
