# Spectrogram Analyzer

A real-time audio analysis tool for macOS that visualizes frequency data using a spectrogram (waterfall) and a spectrum view.

## Features

- **Real-time Spectrogram (Waterfall)**: Visualizes the history of frequency intensities over time.
- **Spectrum View**: Displays the instantaneous frequency magnitude spectrum.
- **Interactive Inspection**:
    - Hover over the waterfall or spectrum to see specific frequency and magnitude values.
    - Click on the waterfall to "snapshot" a moment in time and view its specific frequency spectrum in the detail view.
- **Playback Control**: Pause and resume the visualization analysis.
- **Audio Processing**: High-performance FFT analysis using Apple's `Accelerate` framework.

## Requirements

- **macOS**: The application is built using native macOS frameworks (`Cocoa`, `AVFoundation`, `Accelerate`).
- **Clang**: A C++ compiler supporting C++17 and Objective-C++.

## Build & Run

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/77Aymeric/spectrogram_app.git
    cd spectrogram_app
    ```

2.  **Build the application:**
    ```bash
    make
    ```
    This will compile the source code and create `NoiseReductor.app` in the current directory.

3.  **Run the application:**
    ```bash
    open NoiseReductor.app
    ```
    *Note: The first time you run the app, macOS might ask for microphone permissions to capture audio for analysis.*

## Source Files

- `App.mm`: Main application entry point, UI implementation (WaterfallView, SpectrumView), and audio engine setup using `AVAudioEngine`.
- `AudioProcessor.hpp`: Header file defining audio processing callbacks.
- `Makefile`: Build script to compile the Objective-C++ code into a macOS application bundle.

## License

This project is open-source.
