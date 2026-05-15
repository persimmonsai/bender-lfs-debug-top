import fitz  # PyMuPDF
import pdfplumber
import json
import os
import sys
from pathlib import Path

def convert_pdf_to_md_and_json(pdf_path: str):
    print(f"Processing: {pdf_path}")
    pdf_file = Path(pdf_path)
    if not pdf_file.exists():
        print(f"Error: {pdf_path} not found.")
        return
        
    md_path = pdf_file.with_suffix(".md")
    json_path = pdf_file.with_suffix(".json")
    
    print(f"Extracting Markdown to {md_path.name}...")
    try:
        doc = fitz.open(pdf_file)
        md_text = ""
        for page in doc:
            md_text += page.get_text("markdown") + "\n\n"
        
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(md_text)
        print(f"Successfully wrote {md_path.name}")
    except Exception as e:
        print(f"Failed to extract markdown from {pdf_path}: {e}")

    print(f"Extracting Tables to {json_path.name}...")
    tables_data = []
    try:
        with pdfplumber.open(pdf_file) as pdf:
            for i, page in enumerate(pdf.pages):
                tables = page.extract_tables()
                if tables:
                    for j, table in enumerate(tables):
                        tables_data.append({
                            "page": i + 1,
                            "table_index_on_page": j,
                            "data": table
                        })
                        
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(tables_data, f, indent=2, ensure_ascii=False)
        print(f"Successfully wrote {json_path.name} with {len(tables_data)} tables.")
    except Exception as e:
        print(f"Failed to extract tables from {pdf_path}: {e}")

if __name__ == "__main__":
    target_pdfs = [
        "JESD270-4.pdf",
        "Micron_HBM3E_Datasheet_RevL (3).pdf"
    ]
    
    # Run from the doc directory
    os.chdir(Path(__file__).parent)
    
    for pdf in target_pdfs:
        convert_pdf_to_md_and_json(pdf)
        print("-" * 40)
    
    print("All conversions complete!")
