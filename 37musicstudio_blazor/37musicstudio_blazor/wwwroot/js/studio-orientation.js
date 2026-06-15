window.studioOrientation = window.studioOrientation || {
    async lockLandscape() {
        const result = {
            fullscreenStarted: false,
            locked: false,
            orientation: "",
            message: ""
        };

        try {
            const root = document.documentElement;
            root.classList.add("studio-ledger-landscape-active");

            if (!document.fullscreenElement && root.requestFullscreen) {
                await root.requestFullscreen();
                result.fullscreenStarted = true;
            }
        } catch (error) {
            result.message = error && error.message ? error.message : "Fullscreen request blocked";
        }

        try {
            if (screen.orientation && screen.orientation.lock) {
                await screen.orientation.lock("landscape");
                result.locked = true;
                result.orientation = screen.orientation.type || "landscape";
            }
        } catch (error) {
            result.message = error && error.message ? error.message : result.message || "Orientation lock blocked";
        }

        return result;
    },

    async unlock() {
        try {
            if (screen.orientation && screen.orientation.unlock) {
                screen.orientation.unlock();
            }
        } catch {
            // Ignore browser-specific orientation unlock failures.
        }

        try {
            document.documentElement.classList.remove("studio-ledger-landscape-active");

            if (document.fullscreenElement && document.exitFullscreen) {
                await document.exitFullscreen();
            }
        } catch {
            // Ignore browser-specific fullscreen exit failures.
        }

        return true;
    }
};
