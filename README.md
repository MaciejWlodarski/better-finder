# BetterFinder

Natywny menedżer plików dla macOS 14 lub nowszego, napisany w SwiftUI i AppKit. Łączy przeglądanie plików, wyszukiwanie w indeksie i analizę zajętości dysku.

## Budowanie i uruchomienie

Wymagane są Apple Command Line Tools ze Swiftem 5.10 lub nowszym.

```sh
./build_app.sh
open BetterFinder.app
```

Skrypt buduje aplikację dla architektury bieżącego Maca i podpisuje ją lokalnie. Zachowuje poprzedni bundle aż do udanej kompilacji, wygenerowania ikony i podpisania. Usuwa wyłącznie własny katalog tymczasowy.

## Interfejs i codzienna praca

- Natywny toolbar z nawigacją, wyborem widoku, sortowaniem, udostępnianiem i menu czynności. Wyszukiwanie ma osobny, czytelny pasek; filtry są dostępne z menu i pojawiają się jako usuwalne etykiety.
- Regulowane szerokości paska bocznego, paneli plików i inspektora. Sidebar i inspektor można ukrywać. Systemowe kolory i materiały obsługują jasny i ciemny motyw macOS.
- Lista, siatka ikon, kolumny i mapa zajętości dysku. Lista dostosowuje widoczne kolumny do dostępnego miejsca. Wyszukiwanie w trybie kolumn lub mapy dysku pokazuje wspólną listę wyników.
- Karty z menu kontekstowym: powielanie, zamykanie pozostałych i przywracanie ostatnio zamkniętej karty. Aplikacja zapamiętuje ścieżki otwartych kart i aktywną kartę.
- Zaznaczanie z ⌘ i ⇧, rozszerzanie zakresu strzałkami, zaznaczanie wszystkich oraz przewijanie do zaznaczenia. Zmiana nazwy działa we wszystkich widokach i pokazuje błędy bez zamykania okna edycji.
- Klikalna ścieżka z ręcznym wpisywaniem, obsługą `~` i ścieżek względnych. Nieprawidłowy folder wyświetla komunikat przy polu.
- Lista pojawia się przed odczytem tagów; blokujący dostawca metadanych nie zatrzymuje startu okna. Odczyty tagów, ikon plików i list aplikacji „Otwórz w…” działają w ograniczonych kolejkach w tle.
- Inspektor z podglądem, metadanymi, tagami i sumami kontrolnymi. Przy wielu zaznaczonych elementach pokazuje podsumowanie całego zaznaczenia.
- Przeciąganie całego zaznaczenia w liście i siatce ikon. Zrzut wielu plików jest pojedynczą operacją; ⌥ wymusza kopiowanie. Standardowy zrzut pomiędzy woluminami kopiuje pliki.
- Dwa panele z porównaniem bezpośredniej zawartości folderów i kopiowaniem różnic lub zaznaczenia do drugiego panelu. To nie jest rekurencyjna synchronizacja: wspólne podfoldery są oznaczane jako nieporównane, a konflikty typów wymagają ręcznego rozstrzygnięcia. Zwykłe pliki są porównywane według treści i czasu modyfikacji; zastępowanie wymaga wyboru polityki konfliktu.
- Pasek stanu z liczbą elementów, rozmiarem zaznaczenia, miejscem na woluminie oraz komunikatami operacji. Transfer obejmujący wiele plików można przerwać po bieżącym pliku.

## Wyszukiwanie

Silnik korzysta z `getattrlistbulk`, indeksu w pamięci, opcjonalnej pamięci podręcznej `mmap` i obserwacji `FSEvents`. Zakres **Indeks plików** oznacza skonfigurowane katalogi indeksowania, a nie automatycznie cały dysk. Można też przeszukiwać bieżący folder albo jego podfoldery.

Przykładowe zapytania:

```text
raport ext:pdf
size:>10mb mtime:<7d
type:image
in:Sources grep:TODO
git:modified
"dokładna nazwa" !test
```

Dostępne są także `regex:`, `tag:`, `!ext:`, prefiksy `^`, sufiksy `$` i tolerancja literówek. Pomoc składni jest w menu **Filtry**. Wyszukiwanie można zapisać w pasku bocznym jako inteligentny folder. Zmiany w indeksie i objętych zapytaniem katalogach odświeżają wyniki; starsze żądania nie mogą nadpisać nowszego widoku.

## Skróty

| Skrót | Czynność |
| --- | --- |
| ⌘T / ⌘W | Nowa karta / zamknięcie karty lub ostatniego okna |
| ⇧⌘T | Przywróć zamkniętą kartę |
| ⌃Tab / ⇧⌃Tab | Następna / poprzednia karta |
| ⌘F / ⌘P | Wyszukiwanie / szybkie wyszukiwanie |
| ⌘L / ⇧⌘G | Wpisz ścieżkę folderu |
| ⌘[ / ⌘] / ⌘↑ | Wstecz / dalej / folder nadrzędny |
| ⌘R | Odśwież folder i aktywne wyszukiwanie |
| ⌘1–4 | Lista / ikony / kolumny / mapa dysku |
| ⌘A / ⇧↑↓ | Zaznacz wszystko / rozszerz zaznaczenie |
| Return / Spacja | Zmień nazwę / Quick Look |
| ⇧⌘N / ⌥⌘N | Nowy folder / plik |
| ⌘C / ⌘X / ⌘V | Kopiuj / wytnij / wklej |
| ⌥⌘C / ⌘Delete | Kopiuj ścieżki / przenieś do Kosza |
| ⌘Z / ⇧⌘Z | Cofnij / ponów operację |
| ⇧⌘. | Ukryte pliki |
| ⌃⌘S / ⌘I | Pasek boczny / inspektor |
| ⇧⌘D / ⌃` | Dwa panele / terminal |

Skróty edycji działają na tekście, gdy aktywne jest pole wyszukiwania, ścieżki lub nazwy.

## Operacje i odzyskiwanie

Przy zastępowaniu pliku aplikacja najpierw przygotowuje dane wejściowe, a poprzedni element zachowuje w Koszu. Błąd uruchamia próbę przywrócenia. Undo/Redo obejmuje również zastąpiony element. Nieudane kroki pozostają dostępne do ponowienia; jeśli automatyczne przywrócenie się nie powiedzie, komunikat wskazuje zachowane dane.

Skanowanie i wyszukiwanie oznaczają wyniki częściowe, jeśli osiągnięto limit lub nie odczytano wszystkich danych. Rozmiar katalogu z symbolem ≥ oraz suma „co najmniej” są dolnym oszacowaniem, nie dokładnym rozmiarem. Czyszczenie duplikatów ponownie sprawdza treść i tożsamość plików, w tym zachowywanego egzemplarza, oraz przerywa operację po wykryciu zmiany. Nie jest to blokada plików przed równoczesnym zapisem przez inne aplikacje.

Kompresja i rozpakowywanie tworzą wynik w prywatnym katalogu roboczym, a następnie publikują go bez zastępowania cudzych danych. Jeśli wolumin nie potwierdza obsługi bezpiecznej publikacji wyłącznej, operacja kończy się błędem; zachowane dane robocze są wskazane w komunikacie.

Historia operacji jest przechowywana w pamięci i nie stanowi dziennika odzyskiwania po awarii procesu. Anulowanie transferu działa pomiędzy plikami. Opróżnienie Kosza wymaga potwierdzenia i jest nieodwracalne. Zmiana koloru tagu zachowuje własne, nazwane tagi Findera; polecenie „Usuń wszystkie tagi” usuwa je świadomie.

Automatyczny podgląd Git wyłącza wykonywalne helpery fsmonitor oraz filtry clean/process i nie analizuje zawartości submodułów. Jest to porównanie surowych plików: w repozytoriach z filtrami, np. Git LFS, plik może być oznaczony jako zmieniony mimo czystego statusu w zaufanym Git. Błąd lub przekroczenie limitu inspekcji oznacza brak dostępnego statusu, nie „czyste repozytorium”.

## Przywracanie sesji

Sesja zapamiętuje lokalnie kolejność kart, oba panele, aktywną stronę, widok, sortowanie, ukryte pliki, fuzzy oraz zapytanie i jego zakres. Po ponownym uruchomieniu zapisane widoki są **wstrzymane**. Przycisk „Wznów zapisany widok” odczytuje wybrany folder oraz świadomie uruchamia zapisane wyszukiwanie lub analizę. Nie jest to automatyczne otwarcie wszystkich folderów przy starcie. Wybranie zapisanego wyszukiwania całego indeksu może pokazać jego wyniki bez otwierania wstrzymanego folderu; po wyczyszczeniu zapytania folder nadal wymaga wznowienia.

Nieosiągalna lokalizacja pozostaje widoczna z własną ścieżką i ustawieniami. Można ponowić odczyt albo wybrać inną lokalizację. Przekroczenie czasu oczekiwania nie oznacza usunięcia folderu. Odtwarzanie nie dodaje katalogów do indeksu; zwykłe uruchomienie wcześniej skonfigurowanego indeksowania pozostaje odrębnym mechanizmem aplikacji.

W ustawieniach „Zapisuj i przywracaj sesję” działa natychmiast, niezależnie od zapisu konfiguracji indeksu. Wyłączenie zatrzymuje nowe zapisy i odtwarzanie, zachowując poprzedni zapis. Ponowne włączenie zapisuje bieżący układ. „Wyczyść zapis sesji i wyłącz przywracanie” usuwa tylko zapis sesji oraz stary zapis ścieżek kart i wyłącza dalsze zapisy do ponownego włączenia opcji. Nie zamyka otwartych kart ani nie usuwa inteligentnych folderów i zakładek. Nieobsługiwany/uszkodzony zapis jest chroniony przed nadpisaniem do świadomego wyczyszczenia.

Zaznaczenie, schowek, Undo/Redo, terminal, wyniki analizy i niedokończone operacje nie są zapisywane. Dane sesji nie są wysyłane ani synchronizowane przez aplikację. Nazwane przestrzenie robocze nie są jeszcze obsługiwane.

## Sprawdzenia

```sh
./scripts/run_tests.sh
```

Runner kompiluje rzeczywiste modele, silniki i widoki w izolowanym trybie testowym (osobny katalog domowy, ustawienia i dane tymczasowe) oraz wykonuje testy na plikach tymczasowych; nie wymaga XCTest ani makr Swift Testing. Dodatkowy zestaw testuje zastępowanie, rollback, historię operacji, własność schowka i metadane tagów. Testy zastępowania używają kontrolowanego zamiennika Kosza; nie opróżniają systemowego Kosza ani nie zmieniają schowka.

Podgląd natywnego GUI na danych testowych (w aktywnej sesji graficznej macOS):

```sh
./scripts/preview_app.sh
```

Uruchamia osobny bundle, sprawdza zdarzenia klawiatury i zapisuje rendery własnego okna do `.build/previews`. Obejmuje listę, wyszukiwanie, wąskie okno, dwa panele, inspektor, zmianę nazwy oraz ciemny motyw z ikonami. Nie wymaga przechwytywania ekranu ani dostępu do systemowego Kosza.

Automatyczny workflow `.github/workflows/macos-regressions.yml` buduje aplikację i uruchamia zestawy regresji na macOS. Nie zastępuje ręcznej kontroli GUI, Quick Look, FSEvents, woluminów ani Thread Sanitizera. Samo dodanie workflow nie oznacza, że testy zostały wykonane.
