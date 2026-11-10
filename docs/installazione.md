# NexStream per iPhone e Apple TV — installazione

Le app non passano dall'App Store: si installano firmandole con un certificato personale.
La compilazione avviene su GitHub (repository privato `danieleterminio/nexstream-apple`), che produce due file **non firmati**:

| File | Dispositivo |
|---|---|
| `NexStream-<versione>-ios-unsigned.ipa` | iPhone (iOS 26 o successivo) |
| `NexStream-<versione>-tvos-unsigned.ipa` | Apple TV (tvOS 26 o successivo) |

## 1. Ottenere i file

Da un terminale nella cartella del progetto (`C:\Users\Daniele\NexStreamApple`):

```
gh workflow run build.yml -f what=ipa
gh run watch
gh run download --name out --dir build\ipa
```

I due `.ipa` finiscono in `build\ipa`. Una copia dell'ultima versione sta anche sul NAS, in `Netflix+\NexStreamApple\ipa`.

## 2. iPhone, con il certificato legato all'UDID

1. Apri lo strumento di firma che usi di solito con quel certificato (ESign, Sideloadly, AltStore o simili).
2. Carica `NexStream-…-ios-unsigned.ipa`, scegli certificato (`.p12`) e profilo (`.mobileprovision`).
3. L'identificativo dell'app è `app.nexstream.one`. Se il profilo non è "wildcard", lascia che lo strumento lo cambi con quello del profilo.
4. Firma e installa. Al primo avvio, se richiesto: Impostazioni › Generali › VPN e gestione dispositivi › autorizza il certificato.

L'app dentro contiene molti piccoli framework (i moduli di Python): lo strumento deve firmarli tutti, cosa che fanno in automatico.

## 3. Apple TV, con l'account sviluppatore di un amico

Serve un Mac con Xcode 26, oppure uno strumento di firma che supporti tvOS.

**Con un Mac**
1. Sull'Apple TV: Impostazioni › Telecomandi e dispositivi › App e dispositivi remoti. Sul Mac, in Xcode: Window › Devices and Simulators, abbina l'Apple TV.
2. L'UDID dell'Apple TV va registrato nell'account sviluppatore, e serve un profilo di sviluppo tvOS per `app.nexstream.one` (o wildcard).
3. Firma l'ipa con il certificato dell'account (ad esempio `fastlane sigh resign`, oppure iOS App Signer) e trascina il risultato sulla lista delle app dell'Apple TV in Devices and Simulators.

Con un account a pagamento l'app dura un anno, poi va firmata di nuovo. I dati restano.

## 4. Primo avvio

1. **VPN**: l'app parte solo con una VPN attiva (NordVPN ha l'app sia per iPhone sia per Apple TV). Senza VPN resta sulla schermata "Accendi la VPN".
2. **Linea**: nome utente e password. Sull'Apple TV c'è anche "Accedi dal telefono" (codice QR).
3. **Profili**: creane uno, oppure copia quelli dell'app Android da Impostazioni › "Copia o invia i profili".

## Differenze rispetto ad Android

- **Apple TV e dati**: tvOS può svuotare la memoria temporanea di un'app chiusa. Canali, guida e immagini si riscaricano da soli; profili, preferiti, "Da guardare" e posizioni vengono ripristinati da una copia di sicurezza interna.
- **Promemoria**: su iPhone arriva la notifica anche ad app chiusa; sull'Apple TV l'avviso compare solo con NexStream aperto (tvOS non ha notifiche).
- **Telecomando dal telefono**: l'iPhone comanda per intero NexStream su Fire TV e box Android. Verso l'Apple TV funzionano cambio canale, ricerca, Home e pausa; per le frecce c'è già il telecomando Apple TV nel Centro di Controllo dell'iPhone.
- **Download** (solo iPhone): l'app deve restare aperta finché il download finisce.
- **Picture in picture e trailer**: non presenti in questa versione.
