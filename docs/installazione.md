# NexStream per iPhone e Apple TV — installazione

Le app non passano dall'App Store: si installano firmandole con un certificato personale.
La compilazione avviene su GitHub (repository privato `danieleterminio/nexstream-apple`), che produce due file **non firmati**:

| File | Dispositivo |
|---|---|
| `NexStream-<versione>-ios-unsigned.ipa` | iPhone (iOS 26 o successivo) |
| `NexStream-<versione>-tvos-unsigned.ipa` | Apple TV (tvOS 26 o successivo), con le righe nella Home (Top Shelf) |
| `NexStream-<versione>-tvos-noext-unsigned.ipa` | Apple TV, la stessa app senza l'estensione Top Shelf (per gli strumenti che firmano un solo identificativo) |

Versione attuale: **1.1.1** (build 4).

## 1. Ottenere i file

Da un terminale nella cartella del progetto (`C:\Users\Daniele\NexStreamApple`):

```
gh workflow run build.yml -f what=ipa
gh run watch
gh run download --name out --dir build\ipa
```

I tre `.ipa` finiscono in `build\ipa`. Una copia dell'ultima versione sta anche sul NAS, in `Netflix+\NexStreamApple\ipa`.

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

**Righe nella Home dell'Apple TV (Top Shelf)**
L'ipa tvOS contiene un'estensione (`PlugIns/NexStreamTopShelf.appex`, identificativo `app.nexstream.one.topshelf`) che mostra sopra l'icona di NexStream "Continua a guardare" e "I tuoi canali preferiti", come le righe nella Home di Android TV. Per averle:
1. Nell'account sviluppatore crea un App Group `group.app.nexstream.one` e attivalo sia per `app.nexstream.one` sia per `app.nexstream.one.topshelf` (i due identificativi espliciti, non wildcard).
2. Crea i due profili di sviluppo tvOS e firma l'ipa con entrambi (`fastlane sigh resign` accetta più profili: `--provisioning_profile "app.nexstream.one=app.mobileprovision" --provisioning_profile "app.nexstream.one.topshelf=topshelf.mobileprovision"`). I permessi sono anche in `docs\NexStreamTV.entitlements`.
3. Sull'Apple TV metti NexStream nella prima riga delle app: le righe compaiono lì sopra. "Seleziona" apre il titolo o il canale, "Play" riprende il film o l'episodio dal punto lasciato.

Senza l'App Group (profilo wildcard o strumento che non lo mette) l'app funziona uguale e sopra l'icona resta l'immagine fissa. Se lo strumento di firma non riesce a firmare l'estensione, usa `NexStream-…-tvos-noext-unsigned.ipa`: è la stessa app senza estensione.

In breve, per la firma della Top Shelf servono: un account sviluppatore a pagamento, **due** identificativi espliciti (`app.nexstream.one` e `app.nexstream.one.topshelf`), lo **stesso App Group** `group.app.nexstream.one` su entrambi, e due profili tvOS che contengano l'UDID dell'Apple TV. Un profilo wildcard (`*`) non può contenere un App Group: in quel caso usa l'ipa `noext`.

## 4. Primo avvio

1. **VPN**: l'app parte solo con una VPN attiva (NordVPN ha l'app sia per iPhone sia per Apple TV). Senza VPN resta sulla schermata "Accendi la VPN", che però su iPhone offre due cose che non escono su internet:
   - **Guarda i download**: i film e gli episodi già salvati si guardano senza VPN e senza rete.
   - **Telecomando**: il telefono comanda la TV di casa (usa solo la rete di casa).
   Con "Riprova" l'app ricontrolla subito la VPN.
2. **Linea**: nome utente e password. Sull'Apple TV c'è anche "Accedi dal telefono" (codice QR).
3. **Profili**: creane uno, oppure copia quelli dell'app Android da Impostazioni › "Copia o invia i profili".

## 5. Il player

- Il video parte **in verticale**: in alto l'immagine, sotto le informazioni e i canali (o gli episodi). Ruotando il telefono, o con il tasto in basso a destra del video, va a **tutto schermo**.
- È il player di sistema: compare nel **Centro di Controllo** e sulla schermata di blocco, si manda in **AirPlay** con il tasto in alto a destra, e uscendo dall'app continua in una **finestra (picture in picture)**.
- I canali che il player di sistema non sa decodificare (rari: vecchi canali in MPEG-2) passano da soli al motore di riserva, che non ha AirPlay né finestra. Se i video non partono, in Impostazioni c'è "Player compatibile" che usa sempre quello.
- AirPlay dei canali in diretta: l'Apple TV (o la TV AirPlay) scarica il video dal telefono, quindi telefono e TV devono essere sulla stessa rete e la VPN deve lasciare passare la rete di casa (in NordVPN: "Accesso alla rete locale").

## 6. Download (iPhone)

Nella pagina di un film o di un episodio la freccia salva il titolo sul telefono; la pagina "Download" (da Home o da Il mio spazio, e dalla schermata della VPN) li elenca.

- **Si guardano offline**: un titolo scaricato parte sempre dalla copia sul telefono, anche quando lo apri dalla sua pagina o da "Continua a guardare".
- **Rete**: "Solo Wi-Fi" (predefinito) oppure "Anche dati mobili". Con i dati mobili un film consuma da 0,5 a 3 GB.
- **Qualità**: Risparmio (circa 480p, 0,5 GB l'ora), Standard (720p, circa 1 GB), Alta (1080p, 2–3 GB), quando la fonte offre più versioni.
- **Pausa, ripresa, riprova** per ogni download (tre puntini o pressione lunga). Due download alla volta. "Elimina tutti i download" e lo spazio occupato e libero sono in fondo alla pagina.
- **Si fermano da soli** e lo dicono in cima alla pagina quando la VPN è spenta, quando lo spazio sta finendo o quando aspettano il Wi-Fi; ripartono da soli, da dove erano rimasti (anche dopo aver chiuso l'app).
- **Senza VPN non esce nulla**: niente ricerca della fonte, niente dati, niente pezzi del video. Ogni blocco scaricato passa dal controllo della VPN.
- **In background**: uscendo dall'app i download continuano per poco (il tempo che iOS concede), poi iOS li riprende quando decide (di solito di notte, in carica). Per finire prima, tieni l'app aperta.
- A download finito arriva una notifica; toccandola si apre la pagina dei download.

## 7. CarPlay

Apple non permette a nessuna app di mostrare video sullo schermo dell'auto. Quello che c'è:

- **In riproduzione**: con qualsiasi certificato, quando riproduci dal telefono l'auto mostra titolo, copertina e i tasti pausa / canale successivo (anche dai comandi al volante).
- **App NexStream sullo schermo dell'auto** (liste di canali, film e serie, solo audio, e ricerca vocale con Siri): compare solo se l'app è firmata con un profilo che contiene i permessi `com.apple.developer.carplay-audio` e, per la voce, `com.apple.developer.siri`. Il permesso CarPlay si chiede ad Apple dall'account sviluppatore (developer.apple.com/contact/carplay, categoria "Audio"); una volta concesso si crea un profilo per `app.nexstream.one` con CarPlay e Siri attivi e si firma l'ipa con quello. Il file `docs\NexStream.entitlements` elenca i permessi da passare allo strumento di firma. Il certificato legato all'UDID di norma non li ha: in quel caso l'app funziona tutta, ma non compare in auto.
- **Video in auto da fermi**: iOS 26 permette di mandare il video in AirPlay allo schermo dell'auto a veicolo parcheggiato, sulle auto che lo supportano. Si usa il tasto AirPlay del player.

## 8. Sincronizzazione tra dispositivi

I dati della linea fanno da account: profili, PIN, lista, preferiti, posizioni dei video, gusti, squadre, promemoria e impostazioni di visione sono gli stessi su ogni dispositivo che entra con quella linea (iPhone, Apple TV, Android, Android TV, Fire TV). I dati stanno in un piccolo database sul tuo account Cloudflare (`nexstream-sync`), cifrati sul dispositivo con una chiave ricavata dalla password della linea.

**Attenzione al primo aggiornamento.** Il primo dispositivo che si collega con una linea rende i suoi profili quelli dell'account. Ogni altro dispositivo con la stessa linea, al primo collegamento, perde i profili locali e prende quelli online. Aggiorna quindi per primo il dispositivo con i profili che vuoi tenere.

In Impostazioni, sotto "Linea", la riga "Sincronizzazione tra dispositivi" mostra l'ultima sincronizzazione e la forza con un tocco.

## 9. "Riproduci su…" e telecomando

Nel player del telefono il tasto con la TV elenca le TV di casa con NexStream aperto (Apple TV, Fire TV, box Android). Scegli la TV: il canale o il film riparte lì dallo stesso punto e il telefono diventa il telecomando, con "Riprendi qui" per tornare sul telefono. La prima volta la TV mostra un codice da scrivere sul telefono. Telefono e TV devono essere sulla stessa rete; se la VPN del telefono blocca la rete di casa, attiva l'accesso alla rete locale.

## Differenze rispetto ad Android

- **Apple TV e dati**: tvOS può svuotare la memoria temporanea di un'app chiusa. Canali, guida e immagini si riscaricano da soli; profili, preferiti, lista e posizioni vengono ripristinati da una copia di sicurezza interna.
- **Promemoria**: su iPhone arriva la notifica anche ad app chiusa; sull'Apple TV l'avviso compare solo con NexStream aperto (tvOS non ha notifiche).
- **Telecomando dal telefono**: l'iPhone comanda per intero NexStream su Fire TV e box Android (la box deve avere NexStream aperto; se la VPN del telefono blocca la rete di casa, attiva l'accesso alla rete locale). Verso l'Apple TV funzionano cambio canale, ricerca, Home e pausa; per le frecce c'è già il telecomando Apple TV nel Centro di Controllo dell'iPhone.
- **Download** (solo iPhone): in background iOS concede poco tempo, quindi i download vanno avanti soprattutto con l'app aperta (vedi sezione 6).
- **Apple TV, menu dei riquadri**: tenendo premuto il tasto centrale del telecomando su un canale, un programma o un titolo si apre il menu di sistema (preferiti, promemoria, la mia lista, segna come visto, togli da "Continua a guardare").
- **Trailer**: non presenti in questa versione.
