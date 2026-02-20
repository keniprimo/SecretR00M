# CalculatorPR0 Support Website

A simple, App Store-friendly support website for the CalculatorPR0 iOS app.

## Folder Structure

```
calculatorpr0-support/
├── README.md              # This file
└── docs/                  # GitHub Pages source folder
    ├── index.html         # Home / Support page
    ├── faq.html           # Frequently Asked Questions
    ├── privacy.html       # Privacy Policy
    ├── terms.html         # Terms of Use
    ├── contact.html       # Contact / Support
    └── styles.css         # Shared stylesheet
```

## Placeholders to Replace

Before deploying, search and replace these placeholders in all HTML files:

| Placeholder | Replace With |
|-------------|--------------|
| `[Your Name/Company]` | Your name or company name |
| `support@yourdomain.com` | Your actual support email |
| `yourdomain.com` | Your actual domain |

### Quick Find/Replace Commands

```bash
# macOS/Linux - run from the docs folder
sed -i '' 's/\[Your Name\/Company\]/Your Actual Name/g' *.html
sed -i '' 's/support@yourdomain\.com/your-real-email@domain.com/g' *.html
```

## Deployment Checklist

### Step 1: Create GitHub Repository

1. Go to [github.com/new](https://github.com/new)
2. Repository name: `calculatorpr0` (or `calculatorpr0-support`)
3. Set visibility: **Public** (required for free GitHub Pages)
4. Click **Create repository**

### Step 2: Upload Files

Option A - Using GitHub Web Interface:
1. Click **Add file** > **Upload files**
2. Drag and drop the entire `docs` folder contents
3. Click **Commit changes**

Option B - Using Git:
```bash
cd calculatorpr0-support
git init
git add .
git commit -m "Initial support site"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/calculatorpr0.git
git push -u origin main
```

### Step 3: Enable GitHub Pages

1. Go to your repository on GitHub
2. Click **Settings** (tab at the top)
3. Scroll down to **Pages** (in the left sidebar)
4. Under **Source**, select:
   - Branch: `main`
   - Folder: `/docs`
5. Click **Save**

### Step 4: Verify Deployment

1. Wait 1-2 minutes for deployment
2. Your site will be available at:
   ```
   https://YOUR-USERNAME.github.io/calculatorpr0/
   ```
3. Check the **Pages** settings for the exact URL

### Step 5: Test All Pages

Verify each page loads correctly:
- `https://YOUR-USERNAME.github.io/calculatorpr0/` (Home)
- `https://YOUR-USERNAME.github.io/calculatorpr0/faq.html`
- `https://YOUR-USERNAME.github.io/calculatorpr0/privacy.html`
- `https://YOUR-USERNAME.github.io/calculatorpr0/terms.html`
- `https://YOUR-USERNAME.github.io/calculatorpr0/contact.html`

## App Store Connect URLs

When submitting to the App Store, use these URLs:

| Field | URL |
|-------|-----|
| **Support URL** | `https://YOUR-USERNAME.github.io/calculatorpr0/` |
| **Privacy Policy URL** | `https://YOUR-USERNAME.github.io/calculatorpr0/privacy.html` |
| **Terms of Use URL** (optional) | `https://YOUR-USERNAME.github.io/calculatorpr0/terms.html` |

## Customization

### Changing Colors

Edit `styles.css` and modify the CSS variables at the top:

```css
:root {
    --color-bg: #ffffff;           /* Background color */
    --color-bg-secondary: #f5f5f7; /* Card background */
    --color-text: #1d1d1f;         /* Main text */
    --color-text-secondary: #86868b; /* Secondary text */
    --color-accent: #0071e3;       /* Links */
    --color-border: #d2d2d7;       /* Borders */
}
```

### Adding a Custom Domain

1. Create a `CNAME` file in the `docs` folder containing your domain:
   ```
   support.yourdomain.com
   ```
2. Configure DNS with your domain provider
3. Update GitHub Pages settings to use your custom domain

## Maintenance

- Update the **Effective Date** in privacy.html and terms.html when making policy changes
- Keep the FAQ updated based on common support questions
- Ensure all links remain working after any changes

## Notes

- No external dependencies (no JavaScript frameworks, no CDN links)
- No cookies, trackers, or analytics
- Mobile responsive
- Loads fast
- App Store compliant language throughout
