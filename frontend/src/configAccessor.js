/**
 * Configuration Accessor Module
 * 
 * Provides type-safe access to configuration values with fallback support.
 * If APP_CONFIG is not available, falls back to hardcoded default values
 * to maintain backward compatibility.
 */

const ConfigAccessor = {
  /**
   * Get authentication configuration
   * @returns {Object} Auth configuration with clientId, authority, redirectUri, and scopes
   */
  getAuthConfig() {
    const config = window.APP_CONFIG?.auth;
    if (!config) {
      console.warn('Using hardcoded auth config fallback - APP_CONFIG.auth not found');
      return {
        clientId: "YOUR_AZURE_CLIENT_ID",
        authority: "https://login.microsoftonline.com/YOUR_AZURE_TENANT_ID",
        redirectUri: "https://YOUR_CLOUDFRONT_DOMAIN/",
        scopes: ["YOUR_AZURE_CLIENT_ID/.default"]
      };
    }
    return config;
  },

  /**
   * Get API endpoint configuration
   * @returns {Object} API configuration with agentcoreEndpoint and wsSignEndpoint
   */
  getApiConfig() {
    const config = window.APP_CONFIG?.api;
    if (!config) {
      console.warn('Using hardcoded API config fallback - APP_CONFIG.api not found');
      return {
        agentcoreEndpoint: "https://YOUR_API_GATEWAY_ID.execute-api.YOUR_REGION.amazonaws.com/invoke",
        wsSignEndpoint: ""
      };
    }
    return config;
  },

  /**
   * Get runtime configuration
   * @returns {Object} Runtime configuration with maxAuthRetries and cookieExpirationMinutes
   */
  getRuntimeConfig() {
    const config = window.APP_CONFIG?.runtime;
    if (!config) {
      console.warn('Using hardcoded runtime config fallback - APP_CONFIG.runtime not found');
      return {
        maxAuthRetries: 2,
        cookieExpirationMinutes: 15
      };
    }
    return config;
  }
};

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
  module.exports = ConfigAccessor;
}
