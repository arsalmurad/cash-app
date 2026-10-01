{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  // Preserve the pinned Flutter service-worker setup. Its recorded deprecation
  // is not addressed by silently dropping offline caching here.
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  config: {
    // Missing script coverage must not cause implicit requests to a font CDN.
    // Common Arabic/Urdu and emoji glyphs are bundled in the app FontManifest.
    fontFallbackBaseUrl: new URL('assets/font-fallback/', document.baseURI).href
  }
});
