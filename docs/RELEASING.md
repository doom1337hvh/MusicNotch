# Making a release

MusicNotch isn't notarized, so releases are signed with a self-signed certificate,
"MusicNotch Local Signing". macOS ties the permissions people grant (Input Monitoring,
Automation) to that signature. **Every release must be signed with the same certificate**;
one signed with any other certificate makes everyone grant those permissions again.

## Once: back up the certificate

The certificate lives in your login keychain (made by `scripts/create-signing-cert.sh`) and
is valid until 2036. If it's lost, it can't be recreated: a new one is a different signature.

1. Open **Keychain Access** and select the **login** keychain, then **My Certificates**.
2. Right-click **MusicNotch Local Signing** → **Export "MusicNotch Local Signing"…**, save it
   as a `.p12` file, and choose a strong password.
3. Keep the file and password somewhere safe, such as a password manager. **Never commit it.**

To restore it on another Mac, double-click the `.p12` to import it into the login keychain.
The first build afterwards asks whether `codesign` may use the key: click **Always Allow**.

## Each release

1. Bump `CFBundleShortVersionString` (for example `1.1.0`) and `CFBundleVersion` (`2`, `3`, …)
   in `Resources/Info.plist`, and commit.
2. Run `scripts/release.sh`. It builds, checks the signature, and writes the `.zip`, the
   `.dmg` and `SHA256SUMS.txt` to `dist/`.
3. Tag and push: `git tag v1.1.0 && git push origin v1.1.0`.
4. On GitHub, draft a release for the tag, attach the three files from `dist/`, and paste
   the install note below into the description.

### Install note for release descriptions

> **First launch:** MusicNotch isn't notarized by Apple, so macOS will say it "could not
> verify" it. Click **Done**, then go to **System Settings → Privacy & Security** and click
> **Open Anyway**. Updating? Replace the app in Applications; your permissions carry over.
> See the [README](https://github.com/doom1337hvh/MusicNotch#install) for details.
