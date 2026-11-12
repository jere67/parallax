// Expo reads this on top of app.json each time the dev server starts. It passes the server
// addresses scripts/tunnel.sh opens to the app, which offers them at sign-in (presets.jac).
// With no addresses set the app offers ports 8100 and 8200 on the dev server's computer.
module.exports = ({ config }) => ({
  ...config,
  extra: {
    ...config.extra,
    parallaxServers: {
      live: process.env.PARALLAX_LIVE_URL || "",
      demo: process.env.PARALLAX_DEMO_URL || "",
    },
  },
});
