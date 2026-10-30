# Get a Let's Encrypt certificate

Create a password-protected PFX for Application Gateway using PowerShell on Windows and manual
DNS validation. This completes [HTTPS setup, Step 2](getting-started.md#production-enable-https-on-the-app-gateway).

## Before you start

- A public hostname you control, such as `copilot.example.com`.
- Permission to add TXT records in its public DNS zone.
- An `A` record pointing the hostname to the gateway's public IP.

**Keep secrets private:** never commit or share private keys, PFX files, passwords, or
base64-encoded PFX data. Base64 is not encryption.

## 1. Install Posh-ACME

Run in PowerShell. Installation is only needed once.

```powershell
Install-Module Posh-ACME -Scope CurrentUser
Import-Module Posh-ACME
Set-PAServer LE_PROD
```

Use **`LE_PROD`** for the gateway. `LE_STAGE` is for testing; its certificates are not publicly trusted.

## 2. Request a certificate

Replace the hostname and email. Review the Let's Encrypt terms before using `-AcceptTOS`.
Choose a strong password and save it securely; you will need it for `appGwHttpsPfxPassword`.

```powershell
$hostname = 'copilot.example.com'
$contactEmail = 'you@example.com'
$pfxPassword = Read-Host 'Choose a PFX password' -AsSecureString

$certificate = New-PACertificate $hostname `
  -Plugin Manual `
  -AcceptTOS `
  -Contact $contactEmail `
  -PfxPassSecure $pfxPassword
```

The command pauses for DNS validation. **Leave this PowerShell window open.**

## 3. Complete DNS validation

1. At your DNS provider, create the **TXT record with the name and value Posh-ACME displays**.
   For `copilot.example.com`, the full name is `_acme-challenge.copilot.example.com`.
   If your provider appends `example.com`, enter only `_acme-challenge.copilot`.
2. Wait for public DNS propagation. In a second PowerShell window, replace the example hostname
   and check the record:

   ```powershell
   Resolve-DnsName -Name '_acme-challenge.copilot.example.com' -Type TXT
   ```

   The value must match the prompt. Local DNS may update before public DNS.
3. Return to the original window and continue when prompted.

After issuance, remove only the temporary challenge TXT value. Keep the gateway's `A` record.

## 4. Use the certificate

Posh-ACME creates `fullchain.pfx`, including the private key and issuing chain. No export is needed.

In the original window, show its expiry date and file path:

```powershell
$certificate | Select-Object Subject, NotAfter, PfxFullChain
$pfxPath = $certificate.PfxFullChain
```

Return to [HTTPS setup, Steps 3-5](getting-started.md#production-enable-https-on-the-app-gateway).
Use `$pfxPath` instead of `'fullchain.pfx'` in the encoding command, and keep `pfx.b64.txt`
outside the repository. Set `appGwHttpsPfxPassword` to your chosen password, supply both
certificate parameters, and redeploy. Remove an explicit `appGwEnableHttps = false`, if present.

## Renew before expiry

Check `NotAfter` and follow the [renewal instructions](https://poshac.me/docs/v4/Functions/Submit-Renewal/).
Repeat DNS validation if prompted, then encode the renewed PFX and redeploy.
**Renewing locally does not update the gateway.**

For help, see [DNS troubleshooting](https://poshac.me/docs/v4/Guides/Troubleshooting-DNS-Validation/)
or the [Posh-ACME tutorial](https://poshac.me/docs/v4/Tutorial/).
