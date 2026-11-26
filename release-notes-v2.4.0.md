## NVIDIA Modded Drivers Signer v2.4.0

New option **Add my GPU to the INF if it is not listed** (on by default). If no INF in the driver folder contains your device ID (for example a laptop GPU such as `DEV_24DC` in an INF without laptop IDs), the tool clones the entry of the most similar listed GPU, saves the original INF to `<driver folder>_original_INF_backup`, then signs as usual. Choose the donor yourself with `DEV_24DC from DEV_2484` in the GPU box.

Not tested on Windows yet: the INF edit was checked against a real NVIDIA INF, the PowerShell code was not run.
