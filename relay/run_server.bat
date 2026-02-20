@echo off
REM Start a simple local HTTP server for running patient.html
REM This is required for loading stimulus files from the Stim folder

echo Starting local server on port 8000...
echo.
echo Open your browser to: http://localhost:8000/patient.html
echo.
echo Press Ctrl+C to stop the server when done.
echo.

python -m http.server 8000

pause
