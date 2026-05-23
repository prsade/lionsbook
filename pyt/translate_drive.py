import os
import io
import time
from bs4 import BeautifulSoup
from deep_translator import GoogleTranslator
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaIoBaseUpload

# Zakres uprawnień - pełny dostęp do dysku Google
SCOPES = ['https://www.googleapis.com/auth/drive']

def get_drive_service():
    """Autoryzacja i połączenie z Google Drive API."""
    creds = None
    if os.path.exists('token.json'):
        creds = Credentials.from_authorized_user_file('token.json', SCOPES)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file('credentials.json', SCOPES)
            creds = flow.run_local_server(port=0)
        with open('token.json', 'w') as token:
            token.write(creds.to_json())
    return build('drive', 'v3', credentials=creds)

def find_folder(service, folder_name, parent_id=None):
    """Wyszukuje folder o podanej nazwie na Google Drive."""
    query = f"mimeType = 'application/vnd.google-apps.folder' and name = '{folder_name}' and trashed = false"
    if parent_id:
        query += f" and '{parent_id}' in parents"
    results = service.files().list(q=query, fields="files(id, name)").execute()
    items = results.get('files', [])
    return items[0]['id'] if items else None

def create_folder(service, folder_name, parent_id):
    """Tworzy nowy folder na Google Drive."""
    file_metadata = {
        'name': folder_name,
        'mimeType': 'application/vnd.google-apps.folder',
        'parents': [parent_id]
    }
    file = service.files().create(body=file_metadata, fields='id').execute()
    return file.get('id')

def list_html_files(service, folder_id):
    """Listuje pliki HTML w danym folderze."""
    query = f"'{folder_id}' in parents and mimeType = 'text/html' and trashed = false"
    results = service.files().list(q=query, fields="files(id, name)").execute()
    return results.get('files', [])

def download_file(service, file_id):
    """Pobiera zawartość pliku tekstowego z Drive do pamięci RAM."""
    request = service.files().get_media(fileId=file_id)
    fh = io.BytesIO()
    downloader = MediaIoBaseDownload(fh, request)
    done = False
    while done is False:
        status, done = downloader.next_chunk()
    return fh.getvalue().decode('utf-8', errors='ignore')

def upload_file(service, file_name, content, parent_id):
    """Wysyła przetłumaczony plik HTML z pamięci RAM z powrotem na Google Drive."""
    file_metadata = {
        'name': file_name,
        'parents': [parent_id]
    }
    media = MediaIoBaseUpload(io.BytesIO(content.encode('utf-8')), mimetype='text/html')
    service.files().create(body=file_metadata, media_body=media, fields='id').execute()

def translate_html_content(html_code):
    """Parsuje HTML, bezpiecznie tłumaczy tekst i pokazuje procentowy postęp w konsoli."""
    soup = BeautifulSoup(html_code, 'html.parser')
    translator = GoogleTranslator(source='en', target='pl')
    
    tags_to_translate = soup.find_all(['p', 'li', 'h1', 'h2', 'h3', 'h4'])
    total_tags = len(tags_to_translate)
    
    print(f" -> Znaleziono {total_tags} elementów tekstowych w tym pliku. Start...")
    
    for idx, tag in enumerate(tags_to_translate, 1):
        if tag.find('a') and any(word in tag.get_text() for word in ['Next', 'Previous', 'Contents']):
            continue
            
        original_text = tag.get_text().strip()
        
        if original_text and not original_text.isspace():
            try:
                words = original_text.split()
                if len(words) > 50:
                    chunks = []
                    current_chunk = []
                    for word in words:
                        current_chunk.append(word)
                        if len(current_chunk) >= 50:
                            chunks.append(" ".join(current_chunk))
                            current_chunk = []
                    if current_chunk:
                        chunks.append(" ".join(current_chunk))
                    
                    translated_chunks = []
                    for chunk in chunks:
                        translated_chunks.append(translator.translate(chunk))
                    translated_text = " ".join(translated_chunks)
                else:
                    translated_text = translator.translate(original_text)
                
                tag['title'] = original_text
                tag.string = translated_text
                
            except Exception as e:
                pass
        
        if idx % max(1, int(total_tags * 0.05)) == 0 or idx == total_tags:
            percent = int((idx / total_tags) * 100)
            print(f"\r    [ Postęp w pliku: {percent}% ({idx}/{total_tags}) ]", end="", flush=True)
            
    print() 
    return str(soup)

def main():
    service = get_drive_service()
    
    print("Szukam folderu 'LionsBook'...")
    lions_book_id = find_folder(service, "LionsBook")
    
    if not lions_book_id:
        print("Nie znaleziono folderu 'LionsBook' na Twoim Google Drive!")
        return
        
    print(f"Znaleziono folder 'LionsBook' (ID: {lions_book_id}).")
    
    pol_folder_id = find_folder(service, "POL", parent_id=lions_book_id)
    if not pol_folder_id:
        print("Tworzę folder 'POL'...")
        pol_folder_id = create_folder(service, "POL", parent_id=lions_book_id)
    else:
        print("Folder 'POL' już istnieje.")
        
    files = list_html_files(service, lions_book_id)
    print(f"Znaleziono {len(files)} plików HTML do przetłumaczenia.")
    
    for file in files:
        print(f"Przetwarzanie pliku: {file['name']}...")
        html_content = download_file(service, file['id'])
        translated_content = translate_html_content(html_content)
        
        for proby in range(1, 4):
            try:
                upload_file(service, file['name'], translated_content, pol_folder_id)
                print(f"Zapisano przetłumaczony plik {file['name']} w folderze POL.")
                break
            except Exception as e:
                print(f"    [!] Błąd sieci przy wysyłaniu (Próba {proby}/3). Odpoczywam 10s... Szczegóły: {e}")
                time.sleep(10)
        else:
            print(f"    [X] Nie udało się wysłać pliku {file['name']} po 3 próbach. Przechodzę do kolejnego.")
            
        time.sleep(3)
        
    print("Zakończono tłumaczenie wszystkich plików!")

if __name__ == '__main__':
    main()