# Distributing Windowsill

Every push builds `Windowsill.dmg` and `Windowsill.zip` in GitHub Actions (`.github/workflows/build.yml`).
What those files are depends on which repository secrets exist. With none, you get today's build: it
runs, but macOS blocks it the first time someone opens a downloaded copy. With a Developer ID
certificate and notarization credentials, the same pipeline signs it, has Apple notarize it, and staples
the ticket to both the app and the dmg, so it opens like any other downloaded app.

| Secrets set | App signature | Notarized | Someone who downloads it sees |
|---|---|---|---|
| none | ad hoc | no | a block; they must use **Open Anyway** (below) |
| `MACOS_CERT_P12` + `MACOS_CERT_PASSWORD` | Developer ID, hardened runtime | no | still a block: Gatekeeper wants notarization too |
| the certificate + one complete set of notarization secrets | Developer ID, hardened runtime | yes, ticket stapled to app and dmg | the usual "downloaded from the Internet, open it?" prompt, once |
| notarization secrets without the certificate, or half a set | the run fails on purpose, saying which is missing | | |

The steps below are one-time setup; only you can do them, because they need your Apple Account.

## 1. Join the Apple Developer Program

Signing and notarizing need a paid membership: **99 USD per membership year** (Apple shows the price in
your local currency while you enrol; nonprofits, schools and government bodies can ask for a fee
waiver). Enrol at <https://developer.apple.com/programs/enroll/>. You need an Apple Account with
two-factor authentication turned on, your legal name in its first and last name fields, and to be of
legal age where you live. Enrolling as an organization also needs a D-U-N-S Number. Enrolling as an
individual is simpler, and your legal name then appears as the developer in the app's signature.

Approval is not instant; allow a couple of days. Your **Team ID** (10 characters) is on
<https://developer.apple.com/account> under Membership details; you need it for the Apple ID route in step 5.

## 2. Create a Developer ID Application certificate

"Developer ID Application" is the certificate for apps distributed outside the Mac App Store. Only the
team's Account Holder can create one; as an individual member, that is you. Do this on your Mac.

**With Xcode** (simplest): Xcode > Settings > Accounts, add your Apple Account if it is not there, select
your team, click **Manage Certificates...**, click **+** and choose **Developer ID Application**. Xcode
creates the private key in your login keychain and installs the certificate next to it.

**Without Xcode:**
1. Open Keychain Access, then Keychain Access > Certificate Assistant > **Request a Certificate From a
   Certificate Authority...**. Enter your email and name, leave CA Email empty, choose **Saved to disk**.
   This writes a `.certSigningRequest` file and keeps the matching private key in your login keychain.
2. At <https://developer.apple.com/account/resources/certificates/list> click **+**, choose
   **Developer ID Application**, keep the default (G2) intermediate, upload the request file, and
   download the `.cer` it gives you.
3. Double-click the `.cer`. Keychain Access pairs it with the private key from step 1.

## 3. Export it as a .p12

In Keychain Access, select the **login** keychain and the **My Certificates** tab. Find
"Developer ID Application: Your Name (TEAMID)"; its disclosure triangle should show a private key under
it (if it does not, you are on a Mac that lacks the key: export from the Mac that made the request).
Right-click the certificate > **Export...**, choose **Personal Information Exchange (.p12)**, save it as
`DeveloperID.p12`, and set a strong export password. Keep the .p12 and its password in your password
manager: anyone holding both can sign software as you.

## 4. Notarization credentials: an API key (preferred) or an app-specific password

Pick one.

**App Store Connect Team API key.** At <https://appstoreconnect.apple.com> go to **Users and Access >
Integrations > App Store Connect API**, select **Team Keys** (the first time, the Account Holder clicks
**Request Access** and accepts the terms), then **Generate API Key** (or **+**). Name it "Windowsill
notarization" and give it **Developer** access. Then:
- **Download API Key** gives `AuthKey_<KEYID>.p8`. Apple lets you download it **once**; store it safely.
- The **Key ID** is in the key's row (10 characters).
- The **Issuer ID** (a UUID) is shown above the list of keys.

**Or an app-specific password.** At <https://account.apple.com> go to **Sign-In and Security >
App-Specific Passwords**, generate one named "Windowsill notarization", and copy it (it is shown once).
You will also need your Apple Account email and the Team ID from step 1. Your normal Apple Account
password does not work here.

## 5. Put them in GitHub as repository secrets

Run these in Terminal from inside your clone of the repository (or add `--repo AmeenShareif/windowsill`
to each `gh secret set`). Work in a scratch folder and delete it at the end; the `pbpaste` lines take a
value you have copied, so a password never lands in your shell history.

```bash
mkdir ~/windowsill-secrets && cd ~/windowsill-secrets
cp ~/Downloads/DeveloperID.p12 .            # from step 3, wherever you saved it

# The certificate (base64 of the .p12) and its export password
base64 -i DeveloperID.p12 -o MACOS_CERT_P12.txt
gh secret set MACOS_CERT_P12 < MACOS_CERT_P12.txt
pbpaste > MACOS_CERT_PASSWORD.txt           # after copying the .p12 export password
gh secret set MACOS_CERT_PASSWORD < MACOS_CERT_PASSWORD.txt
```

Then **either** the API key (preferred):

```bash
cp ~/Downloads/AuthKey_ABC123DEFG.p8 .       # your Key ID in place of ABC123DEFG
base64 -i AuthKey_ABC123DEFG.p8 -o NOTARY_KEY_P8.txt
gh secret set NOTARY_KEY_P8 < NOTARY_KEY_P8.txt
printf '%s' ABC123DEFG > NOTARY_KEY_ID.txt
gh secret set NOTARY_KEY_ID < NOTARY_KEY_ID.txt
printf '%s' 01234567-89ab-cdef-0123-456789abcdef > NOTARY_ISSUER_ID.txt   # your Issuer ID
gh secret set NOTARY_ISSUER_ID < NOTARY_ISSUER_ID.txt
```

**or** the Apple Account route:

```bash
printf '%s' you@example.com > NOTARY_APPLE_ID.txt                       # your Apple Account email
gh secret set NOTARY_APPLE_ID < NOTARY_APPLE_ID.txt
pbpaste > NOTARY_PASSWORD.txt               # after copying the app-specific password
gh secret set NOTARY_PASSWORD < NOTARY_PASSWORD.txt
printf '%s' ABCDE12345 > NOTARY_TEAM_ID.txt                              # your Team ID
gh secret set NOTARY_TEAM_ID < NOTARY_TEAM_ID.txt
```

Finish with:

```bash
gh secret list                               # the names above should be listed
cd ~ && rm -rf ~/windowsill-secrets
```

If both sets are present, the API key is used. Push any commit (or run the workflow from the Actions
tab) and open the run: the **Import Developer ID certificate** step prints `signing as Developer ID
Application: ...`, and **Package zip and dmg** prints the notarization verdicts (`"status":"Accepted"`)
and Gatekeeper's `source=Notarized Developer ID` for the app and the dmg.

## 6. Cut a release

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The tag's run sets the app's version to 1.0.0 (the build number is the run number), builds, signs,
notarizes, and creates a GitHub Release named "Windowsill 1.0.0" with `Windowsill.dmg` and
`Windowsill.zip` attached and notes generated from the commits since the last release. Use three
numbers: a tag such as `v1.1.0-beta` still makes a release, but the app keeps the version written in
`Resources/Info.plist`, because macOS expects that version to be three integers. The release is made
even without the secrets, so check the run's log for `Accepted` before announcing one.

The repository is public, so anyone can download a release. Every installed copy looks once a day for a
newer release and offers it in its panel with a **Download** button that opens the release page (Settings
> **Check for new versions** turns that off). Only a three-number tag is offered: `v1.1.0-beta` is not.

## 7. Check that a downloaded build is notarized

On any Mac, after downloading (the `xcrun` commands need the Command Line Tools; macOS offers to
install them the first time):

```bash
spctl -a -vvv /Applications/Windowsill.app
#   /Applications/Windowsill.app: accepted
#   source=Notarized Developer ID
#   origin=Developer ID Application: Your Name (TEAMID)
xcrun stapler validate /Applications/Windowsill.app      # The validate action worked!
spctl -a -vvv -t open --context context:primary-signature ~/Downloads/Windowsill.dmg
xcrun stapler validate ~/Downloads/Windowsill.dmg
```

`source=Unnotarized Developer ID` means signed but not notarized; any other `rejected` result on a
build from this pipeline means the ad-hoc one.

## What someone sees opening the unsigned build (macOS 15 Sequoia)

The build made without secrets is signed ad hoc and not notarized. A copy that came from a browser
download or AirDrop carries a quarantine flag, and Gatekeeper refuses to open it: double-clicking
shows a warning that Apple cannot check Windowsill for malicious software, with only **Move to Trash**
and **Done**. There is no Open button.

On macOS 14 and earlier, Control-click > Open got past this. **Sequoia removed that route**: Apple's
announcement (<https://developer.apple.com/news/?id=saqachfa>, August 2024) says users "will no longer
be able to Control-click to override Gatekeeper" and must go to System Settings > Privacy & Security
instead. The steps, from Apple's "Safely open apps on your Mac" (<https://support.apple.com/en-us/102445>):

1. Drag Windowsill from the dmg to Applications, then double-click it there once. Click **Done** on the
   warning.
2. Open System Settings > **Privacy & Security** and scroll down to the Security section. It now names
   Windowsill with an **Open Anyway** button. Click it.
3. The warning comes back, this time with an **Open** button. Click it (authenticate if asked).

macOS saves the app as an exception, so it opens normally from then on. A person comfortable with
Terminal can instead clear the quarantine flag before the first open:

```bash
xattr -dr com.apple.quarantine /Applications/Windowsill.app
```

## Uninstall

1. Click the snowflake in the menu bar, open the **Settings** tab, turn off **Open at login**, and click
   **Quit Windowsill**.
2. If Windowsill still appears in System Settings > General > **Login Items & Extensions** (called
   **Login Items** on macOS 14) under Open at Login, select it and click the minus button.
3. Drag `/Applications/Windowsill.app` to the Trash.
4. Remove its settings in Terminal: `defaults delete app.windowsill`

## When a run fails

| Message in the log | Cause |
|---|---|
| `MACOS_CERT_P12 holds no valid Developer ID Application identity` | The .p12 holds a different certificate (such as "Apple Development") or no private key; export again from My Certificates (step 3). |
| `incomplete notarization credentials` | One set of NOTARY_ secrets is only partly there; add the missing ones or delete the strays. |
| `notarization credentials are set but SIGN_IDENTITY is not` | Notarization secrets exist but the certificate secrets do not. |
| `notarization of ...: Invalid`, followed by a JSON log | Apple refused the build; the log's `issues` list says why. |
| `security: SecKeychainItemImport: MAC verification failed` | `MACOS_CERT_PASSWORD` is not the .p12's export password. |
