import sqlite3
c=sqlite3.connect("file:/opt/acgn-test-platform/local_dev.db?mode=ro",uri=True)
rows=[(str(r[0]),r[1]) for r in c.execute("select id,name from series")]
links=[(str(r[0]),str(r[1])) for r in c.execute("select bangumi_id,series_id from contents where series_id is not null and bangumi_id is not null")]
m={}
for b,s in links:m.setdefault(s,[]).append(b)
L=["START TRANSACTION;"]
if rows:
 L.append("INSERT IGNORE INTO series(series_key,name,created_at,updated_at)VALUES")
 L.append(",\n".join("  ('%s', %s, NOW(3), NOW(3))"%(k,"NULL" if n is None else "'%s'"%str(n).replace("\\","\\\\").replace("'","\\'")) for k,n in rows)+";")
for s,ids in m.items():
 for i in range(0,len(ids),500):
  b=ids[i:i+500]
  L.append("UPDATE work SET series_key='%s' WHERE source='bangumi' AND source_id IN(%s) AND(series_key IS NULL OR series_key='');"%(s,", ".join("'%s'"%x for x in b)))
L.append("COMMIT;")
main="\n".join(L)
rb=["START TRANSACTION;"]
A=[x for v in m.values() for x in v]
if A:rb.append("UPDATE work SET series_key=NULL WHERE source='bangumi' AND source_id IN(%s);" % ", ".join("'%s'" % x for x in A))
if rows:rb.append("DELETE FROM series WHERE series_key IN(%s);" % ", ".join("'%s'" % k for k, _ in rows))
rb.append("COMMIT;")
open("/root/series_backfill.sql","w").write(main)
open("/root/series_rollback.sql","w").write("\n".join(rb))
print(len(rows),len(links),len(A),len(m))
