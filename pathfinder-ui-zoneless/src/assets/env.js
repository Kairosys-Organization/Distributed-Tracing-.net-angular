(function (window) {
    window.env = window.env || {};

    // These values are overwritten at container startup by envsubst
    // from env.template.js using the container's environment variables.
    // Do NOT hardcode URLs here — edit .env instead.
    window.env.API_URL = '';
    window.env.OTEL_URL = '';
})(this);
