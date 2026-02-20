// ============================================================================
// STIMULUS CONFIGURATION FILE
// ============================================================================
//
// This file FULLY DEFINES the session structure. There is no GUI editor.
//
// CORE MODEL:
//   SESSION → TESTS → CSV FILES
//
//   - A Session is an ordered list of Tests
//   - Each Test uses exactly ONE CSV file (selected by global index)
//   - Each Test type has MULTIPLE CSV file variants (same structure, different content)
//   - A single GLOBAL INDEX selects which variant is used for ALL tests
//
// GLOBAL INDEX:
//   - Generated ONCE at session start (random or seeded)
//   - The SAME index is used for EVERY test
//   - If index = 3, then Test A uses file[3], Test B uses file[3], etc.
//   - This ensures reproducible, consistent session variants
//
// IMPORTANT:
//   - All test file arrays MUST have the SAME LENGTH
//   - Index i always refers to the same session variant across all tests
//   - Patients never see file names, indices, or config content
//
// ============================================================================

const StimulusConfig = {

    // ========================================================================
    // SCHEMA VERSION
    // ========================================================================
    version: "2.0",

    // ========================================================================
    // GLOBAL INDEX CONFIGURATION
    // ========================================================================
    // The global index determines which CSV variant is loaded for ALL tests.
    //
    // Example: If totalVariants = 50 and the generated index = 12,
    //          then EVERY test loads its file at position [12].
    //
    indexing: {
        // Total number of session variants (all file arrays must be this length)
        totalVariants: 50,

        // How to determine the index for this session:
        //   "sequential" - Use next index from localStorage (1, 2, 3, ...)
        //   "random"     - Generate random index (optionally seeded)
        //   "fixed"      - Always use fixedIndex value
        mode: "sequential",

        // For "fixed" mode: always use this index
        fixedIndex: 0,

        // For "random" mode: seed for reproducibility (null = use timestamp)
        randomSeed: null,

        // Starting index for "sequential" mode
        startIndex: 0
    },

    // ========================================================================
    // SESSION INSTRUCTIONS
    // ========================================================================
    // Instructions shown at the START and END of the entire session.
    // These wrap around ALL tests.
    //
    sessionInstructions: {
        // Shown BEFORE any tests begin
        start: {
            title: "Welcome",
            text: "Thank you for participating in this study.\n\nYou will complete several short tasks. Each task will have its own instructions.\n\nPlease find a quiet place and minimize distractions.",
            buttonText: "Begin Session"
        },

        // Shown AFTER all tests complete
        end: {
            title: "Session Complete",
            text: "Thank you for completing this session.\n\nYour responses have been recorded.",
            showStatistics: true,  // Show overall performance summary
            buttonText: "Finish"
        }
    },

    // ========================================================================
    // TESTS (Ordered List)
    // ========================================================================
    // Each test is run in sequence. The order here IS the order of execution.
    //
    // For each test:
    //   - id: Unique identifier (used in logs)
    //   - name: Human-readable name (shown in results, not to patient)
    //   - instructions: Shown to patient BEFORE this test starts
    //   - files: Array of CSV file paths (MUST have length = totalVariants)
    //   - enabled: Set to false to skip this test
    //
    tests: [
        {
            id: "AUD_BL",
            name: "Auditory Baseline",
            enabled: true,
            instructions: {
                title: "Auditory Task",
                text: "You will hear a series of tones.\n\nPress SPACE when you hear a HIGHER pitched tone.",
                buttonText: "Start"
            },
            // File array: index i loads files[i]
            files: [
                "Stim/AUD_BL/AUD_BL_v00.csv",
                "Stim/AUD_BL/AUD_BL_v01.csv",
                "Stim/AUD_BL/AUD_BL_v02.csv",
                "Stim/AUD_BL/AUD_BL_v03.csv",
                "Stim/AUD_BL/AUD_BL_v04.csv",
                // ... continues to v49 (totalVariants = 50)
            ]
        },
        {
            id: "AUD_SSL",
            name: "Auditory Statistical Learning",
            enabled: true,
            instructions: {
                title: "Auditory Task",
                text: "You will hear a series of tones.\n\nPress SPACE when you hear a DIFFERENT pattern.",
                buttonText: "Start"
            },
            files: [
                "Stim/AUD_SSL/AUD_SSL_v00.csv",
                "Stim/AUD_SSL/AUD_SSL_v01.csv",
                "Stim/AUD_SSL/AUD_SSL_v02.csv",
                "Stim/AUD_SSL/AUD_SSL_v03.csv",
                "Stim/AUD_SSL/AUD_SSL_v04.csv",
                // ... continues to v49
            ]
        },
        {
            id: "VIS_BL",
            name: "Visual Baseline",
            enabled: true,
            instructions: {
                title: "Visual Task",
                text: "You will see flashing lights on the screen.\n\nPress SPACE when you see a RED flash.",
                buttonText: "Start"
            },
            files: [
                "Stim/VIS_BL/VIS_BL_v00.csv",
                "Stim/VIS_BL/VIS_BL_v01.csv",
                "Stim/VIS_BL/VIS_BL_v02.csv",
                "Stim/VIS_BL/VIS_BL_v03.csv",
                "Stim/VIS_BL/VIS_BL_v04.csv",
                // ... continues to v49
            ]
        },
        {
            id: "VIS_SSL",
            name: "Visual Statistical Learning",
            enabled: true,
            instructions: {
                title: "Visual Task",
                text: "You will see flashing lights on the screen.\n\nPress SPACE when you notice a CHANGE in the pattern.",
                buttonText: "Start"
            },
            files: [
                "Stim/VIS_SSL/VIS_SSL_v00.csv",
                "Stim/VIS_SSL/VIS_SSL_v01.csv",
                "Stim/VIS_SSL/VIS_SSL_v02.csv",
                "Stim/VIS_SSL/VIS_SSL_v03.csv",
                "Stim/VIS_SSL/VIS_SSL_v04.csv",
                // ... continues to v49
            ]
        }
    ],

    // ========================================================================
    // BREAKS BETWEEN TESTS (Optional)
    // ========================================================================
    breaks: {
        enabled: true,
        durationMs: 15000,           // 15 seconds
        showCountdown: true,
        allowSkip: true,
        message: "Take a short break. The next task will begin shortly."
    },

    // ========================================================================
    // AUTO-DOWNLOAD SETTINGS
    // ========================================================================
    autoDownload: {
        enabled: true,
        format: "json",              // "json" or "csv"
        // Filename pattern: {sid} = stimulus index, {timestamp} = ISO timestamp
        filenamePattern: "session_idx{sid}_{timestamp}"
    },

    // ========================================================================
    // LOCALSTORAGE KEYS (for sequential mode tracking)
    // ========================================================================
    storage: {
        lastIndexKey: "stimulus_lastIndex",
        completedKey: "stimulus_completedIndices"
    }
};

// ============================================================================
// VALIDATION HELPER (called by loader)
// ============================================================================
// This function validates that the config is properly structured.
// Returns { valid: true } or { valid: false, errors: [...] }

StimulusConfig.validate = function() {
    const errors = [];

    // Check version
    if (!this.version) {
        errors.push("Missing: version");
    }

    // Check indexing
    if (!this.indexing) {
        errors.push("Missing: indexing section");
    } else {
        if (this.indexing.totalVariants === undefined || this.indexing.totalVariants < 1) {
            errors.push("indexing.totalVariants must be >= 1");
        }
        if (!['sequential', 'random', 'fixed'].includes(this.indexing.mode)) {
            errors.push("indexing.mode must be 'sequential', 'random', or 'fixed'");
        }
    }

    // Check tests
    if (!Array.isArray(this.tests) || this.tests.length === 0) {
        errors.push("tests must be a non-empty array");
    } else {
        const expectedLength = this.indexing?.totalVariants || 0;

        this.tests.forEach((test, i) => {
            if (!test.id) errors.push(`tests[${i}]: missing id`);
            if (!test.name) errors.push(`tests[${i}]: missing name`);
            if (!Array.isArray(test.files)) {
                errors.push(`tests[${i}]: files must be an array`);
            } else if (test.files.length !== expectedLength) {
                errors.push(`tests[${i}]: files array length (${test.files.length}) must match totalVariants (${expectedLength})`);
            }
            if (!test.instructions) {
                errors.push(`tests[${i}]: missing instructions`);
            }
        });
    }

    // Check session instructions
    if (!this.sessionInstructions) {
        errors.push("Missing: sessionInstructions section");
    } else {
        if (!this.sessionInstructions.start) errors.push("Missing: sessionInstructions.start");
        if (!this.sessionInstructions.end) errors.push("Missing: sessionInstructions.end");
    }

    return { valid: errors.length === 0, errors };
};

// ============================================================================
// INDEX GENERATOR (called by loader)
// ============================================================================
// Returns the global stimulus index for this session.

StimulusConfig.getIndex = function() {
    const indexing = this.indexing;
    const total = indexing.totalVariants;

    // Check for URL override: ?index=5
    const urlParams = new URLSearchParams(window.location.search);
    const urlIndex = urlParams.get('index');
    if (urlIndex !== null) {
        const idx = parseInt(urlIndex, 10);
        if (!isNaN(idx) && idx >= 0 && idx < total) {
            console.log(`[StimulusConfig] Using URL index override: ${idx}`);
            return { index: idx, source: 'url_override' };
        }
    }

    switch (indexing.mode) {
        case 'fixed':
            return { index: indexing.fixedIndex, source: 'fixed' };

        case 'random': {
            const seed = indexing.randomSeed || Date.now();
            // Simple seeded random
            const seededRandom = ((seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
            const idx = Math.floor(seededRandom * total);
            return { index: idx, source: 'random', seed };
        }

        case 'sequential':
        default: {
            const lastKey = this.storage?.lastIndexKey || 'stimulus_lastIndex';
            const stored = localStorage.getItem(lastKey);
            let nextIndex = indexing.startIndex || 0;

            if (stored !== null) {
                nextIndex = (parseInt(stored, 10) + 1) % total;
            }

            return { index: nextIndex, source: 'sequential' };
        }
    }
};

// ============================================================================
// MARK INDEX COMPLETE (called after session finishes)
// ============================================================================

StimulusConfig.markIndexComplete = function(index) {
    const lastKey = this.storage?.lastIndexKey || 'stimulus_lastIndex';
    const completedKey = this.storage?.completedKey || 'stimulus_completedIndices';

    // Save last index
    localStorage.setItem(lastKey, index.toString());

    // Add to completed list
    let completed = [];
    try {
        const stored = localStorage.getItem(completedKey);
        if (stored) completed = JSON.parse(stored);
    } catch (e) { /* ignore */ }

    if (!completed.includes(index)) {
        completed.push(index);
        localStorage.setItem(completedKey, JSON.stringify(completed));
    }

    console.log(`[StimulusConfig] Marked index ${index} complete`);
};

// ============================================================================
// GET FILE FOR TEST AT CURRENT INDEX
// ============================================================================

StimulusConfig.getFileForTest = function(testId, index) {
    const test = this.tests.find(t => t.id === testId);
    if (!test) {
        console.error(`[StimulusConfig] Test not found: ${testId}`);
        return null;
    }
    if (index < 0 || index >= test.files.length) {
        console.error(`[StimulusConfig] Index ${index} out of range for test ${testId}`);
        return null;
    }
    return test.files[index];
};

// ============================================================================
// GET ENABLED TESTS
// ============================================================================

StimulusConfig.getEnabledTests = function() {
    return this.tests.filter(t => t.enabled !== false);
};

// Export for module systems (optional)
if (typeof module !== 'undefined' && module.exports) {
    module.exports = StimulusConfig;
}
