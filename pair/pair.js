"use strict";

let downloadRedirect;

function showPairingLink() {
  window.clearTimeout(downloadRedirect);
  const fragment = window.location.hash.slice(1);
  // Remove the secret from browser history before leaving this page. Keep it in
  // memory only, and never append it to the download destination.
  window.history.replaceState(null, "", window.location.pathname);
  const openApp = document.getElementById("open-app");
  const download = document.getElementById("download");
  const status = document.getElementById("status");
  openApp.hidden = true;
  openApp.removeAttribute("href");
  download.hidden = true;
  download.removeAttribute("href");
  const parameters = new URLSearchParams(fragment);
  const keys = [...parameters.keys()];
  const code = (parameters.get("code") || "").toUpperCase().replace(/[\s-]/g, "");
  const name = parameters.get("name");
  const valid = fragment.length <= 512 && keys.length === 3 && new Set(keys).size === 3 &&
    keys.every(key => ["v", "name", "code"].includes(key)) && parameters.get("v") === "1" &&
    /^[0-9A-F]{24}$/.test(code) && name === `Trackypady ${code.slice(0, 8)}`;

  if (valid) {
    const pairing = new URLSearchParams({ v: "1", name, code });
    // URLSearchParams uses + for spaces, whereas the native parser uses %20.
    openApp.href = `trackypady://pair?${pairing.toString().replace(/\+/g, "%20")}`;
    openApp.hidden = false;
  }

  const links = window.trackypadyLinks;
  const appStoreReady = /^https:\/\/apps\.apple\.com\/(?:[a-z]{2}\/)?app\/(?:[\w-]+\/)?id[0-9]+$/.test(links.appStoreURL || "");
  const betaReady = /^https:\/\/testflight\.apple\.com\/(?:j|join)\/[A-Za-z0-9]{8}$/.test(links.testFlightURL || "");
  const downloadURL = appStoreReady ? links.appStoreURL : links.testFlightURL;
  if ((!appStoreReady && !betaReady) || new URL(links.websiteURL).hostname.endsWith(".example.com")) {
    status.textContent = "Downloads are being set up. If you already have the app, open it to pair.";
    if (!valid) status.textContent += " Scan the QR displayed on your Mac for a pairing link.";
    return;
  }

  const destination = appStoreReady ? "the App Store" : "TestFlight";
  download.textContent = appStoreReady ? "Download on the App Store" : "Download with TestFlight";
  download.href = downloadURL;
  download.hidden = false;
  status.textContent = valid
    ? `Install from ${destination}, then scan your Mac QR again.`
    : "Scan your Mac QR after installing to connect your iPhone.";

  if (valid && /iPhone|iPad|iPod/.test(navigator.userAgent)) {
    status.textContent = `Opening ${destination}… After installing, scan your Mac QR again.`;
    downloadRedirect = window.setTimeout(() => window.location.replace(downloadURL), 1500);
  }
}

document.getElementById("open-app").addEventListener("click", () => window.clearTimeout(downloadRedirect));
document.addEventListener("visibilitychange", () => {
  if (document.hidden) window.clearTimeout(downloadRedirect);
});
// A second Camera scan can reuse this page through same-document navigation.
window.addEventListener("hashchange", showPairingLink);
showPairingLink();
