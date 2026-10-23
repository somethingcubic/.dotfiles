import csv


def write_report(rows, path):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["currency", "rate"])
        for cur, rate in sorted(rows.items()):
            w.writerow([cur, rate])
