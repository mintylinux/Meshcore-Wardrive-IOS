import 'dart:ui';

/// Color palettes designed for various types of color vision deficiency
class ColorBlindPalette {
  /// Color blind mode types
  static const String normal = 'normal';
  static const String deuteranopia = 'deuteranopia'; // Red-green (most common)
  static const String protanopia = 'protanopia'; // Red-green
  static const String tritanopia = 'tritanopia'; // Blue-yellow
  
  /// Get success color based on color blind mode
  static Color getSuccessColor(String mode) {
    switch (mode) {
      case deuteranopia:
      case protanopia:
        return const Color(0xFF0077BB); // Blue (safe for red-green deficiency)
      case tritanopia:
        return const Color(0xFFEE3377); // Pink (safe for blue-yellow deficiency)
      case normal:
      default:
        return const Color(0xFF00C853); // Green (normal vision)
    }
  }
  
  /// Get failure/dead zone color based on color blind mode
  static Color getFailureColor(String mode) {
    switch (mode) {
      case deuteranopia:
      case protanopia:
        return const Color(0xFFEE7733); // Orange (safe for red-green deficiency)
      case tritanopia:
        return const Color(0xFF009988); // Teal (safe for blue-yellow deficiency)
      case normal:
      default:
        return const Color(0xFFD32F2F); // Red (normal vision)
    }
  }
  
  /// Get repeater marker color based on color blind mode
  static Color getRepeaterColor(String mode) {
    switch (mode) {
      case deuteranopia:
      case protanopia:
        return const Color(0xFF9933BB); // Purple (distinguishable from blue/orange)
      case tritanopia:
        return const Color(0xFFDDAA33); // Yellow-gold (distinguishable from pink/teal)
      case normal:
      default:
        return const Color(0xFF9C27B0); // Purple (normal vision)
    }
  }
  
  /// Get GPS-only sample color (neutral gray, same for all modes)
  static Color getGpsOnlyColor(String mode) {
    return const Color(0xFF9E9E9E); // Gray (neutral for all modes)
  }
  
  /// Get coverage gradient colors for "age" mode
  static List<Color> getAgeGradient(String mode) {
    switch (mode) {
      case deuteranopia:
      case protanopia:
        // Blue to orange gradient (safe for red-green deficiency)
        return [
          const Color(0xFF0077BB), // Blue (recent)
          const Color(0xFF33BBEE), // Light blue
          const Color(0xFFEE7733), // Orange (old)
        ];
      case tritanopia:
        // Pink to teal gradient (safe for blue-yellow deficiency)
        return [
          const Color(0xFFEE3377), // Pink (recent)
          const Color(0xFFCC6688), // Medium pink
          const Color(0xFF009988), // Teal (old)
        ];
      case normal:
      default:
        // Blue gradient (normal vision)
        return [
          const Color(0xFF1565C0), // Dark blue (recent)
          const Color(0xFF42A5F5), // Medium blue
          const Color(0xFFBBDEFB), // Light blue (old)
        ];
    }
  }
  
  /// Get color for quality-based coverage with interpolation
  static Color getQualityColor(String mode, double successRate) {
    final successColor = getSuccessColor(mode);
    final failureColor = getFailureColor(mode);
    
    // Interpolate between failure and success colors
    return Color.lerp(failureColor, successColor, successRate) ?? successColor;
  }
  
  /// Get all available mode names for UI display
  static List<String> getAllModes() {
    return [normal, deuteranopia, protanopia, tritanopia];
  }
  
  /// Get display name for mode
  static String getDisplayName(String mode) {
    switch (mode) {
      case deuteranopia:
        return 'Deuteranopia (Red-Green)';
      case protanopia:
        return 'Protanopia (Red-Green)';
      case tritanopia:
        return 'Tritanopia (Blue-Yellow)';
      case normal:
      default:
        return 'Normal Vision';
    }
  }
}
