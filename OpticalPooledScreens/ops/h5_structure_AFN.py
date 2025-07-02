import pandas as pd
import sys

def main(filename):
    with pd.HDFStore(filename, 'r') as store:
        print(f"Keys in {filename}:")
        for key in store.keys():
            print(key)
        print("\nMetadata for each key:")
        for key in store.keys():
            print(f"\nKey: {key}")
            try:
                df = store.get(key)
                print(f"  Type: {type(df)}")
                print(f"  Shape: {getattr(df, 'shape', 'N/A')}")
                print(f"  Columns: {getattr(df, 'columns', 'N/A')}")
            except Exception as e:
                print(f"  Could not read: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python h5_structure_pandas.py <file.h5>")
        sys.exit(1)
    main(sys.argv[1])