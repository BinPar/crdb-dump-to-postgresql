#!/bin/bash

uri=$1
database=$2

shouldStopOnError=${ON_ERROR_STOP:-0}

foldername=$(date +%Y%m%d%H%M%S)

fieldDelimiterChar=$(echo "AQ==" | base64 -d -w 0)
recordDelimiterChar=$(echo "Ag==" | base64 -d -w 0)

mkdir $foldername

ddlfilename=$database-ddl.sql
alltablesfilename=$database-alltables.txt
createtypes=$database-types.sql

psql $1 -Ato ./$foldername/$ddlfilename -c "
show create all tables
"

psql $1 -A -c "select name as namedeleteme from crdb_internal.tables where database_name = '$database'" > ./$foldername/$alltablesfilename
psql $1 -Ato ./$foldername/$createtypes -c "show create all types"

pushd $foldername

awk '
# create extensions that are default in CR
NR==1{
 print "create extension if not exists pgcrypto;" > "tab-"FILENAME
}
# remove all reference to schema public
#/TABLE public[.]/{
# $0=gensub(/(REFERENCES |TABLE )public[.]/,"\\1","g")
#}
# remove all reference to default values as :::TYPE
/DEFAULT.*?:::/{
 $0=gensub(/(DEFAULT.*?):::.*?$/,"\\1,","g")
}
# remove all reference to ordering in PRIMARY KEYs taking into account that can be multiple PRIMARY KEYs
/PRIMARY KEY/{
 primarykeypart=gensub(/(PRIMARY KEY.*?[(]).*/,"\\1",1)
 indexpropspart=gensub(/.*PRIMARY KEY[^(]*[(]([^)]*)[)]/,"\\1)",1)
 propswithoutorder=gensub(/( ASC| DESC)/, "", "g", indexpropspart)
 $0=primarykeypart""propswithoutorder
}
/GEOMETRY/{
  $0=gensub(/GEOMETRY[(](.*?),.*?[)]/,"\\1","g")
}
/current_timestamp/{
  $0=gensub(/(current_timestamp)[(][)]/,"\\1","g")
}
# change STRING type to TEXT type
/STRING (NOT )?NULL/{
 $0=gensub(/ STRING /," TEXT ","g")
}
# change STRING(X) type to VARCHAR(X) type
/STRING[(][0-9]*[)] (NOT )?NULL/{
 $0=gensub(/ STRING([(][0-9]*[)]) /," VARCHAR\\1 ","g")
}
# change BYTES type to BYTEA type
/BYTES (NOT )?NULL/{
 $0=gensub(/ BYTES /," BYTEA ","g")
}
# change BOOL type to BOOLEAN type
/BOOL (NOT )?NULL/{
 $0=gensub(/ BOOL /," BOOLEAN ","g")
}
# change INT8 type to BIGINT type
/INT8 (NOT )?NULL/{
 $0=gensub(/ INT8 /," BIGINT ","g")
}
# change MAXVALUE 9223372036854775807 type to MAXVALUE 2147483647 if INT4 type
/INT4 MINVALUE 1 MAXVALUE 9223372036854775807/{
 $0=gensub(/(INT4 MINVALUE 1 MAXVALUE) 9223372036854775807/,"\\1 2147483647","g")
}
# move commas at the end of lines to the begining of next line
nextline!=""{
 $0=gensub(/(^\t*)(.*)$/,"\\1"nextline"\\2",1)
 nextline=""
}
/,$/{
 sub(/,$/,"")
 nextline=","
}
# INDEX clause in the CREATE TABLE is not a SQL syntax
/^CREATE TABLE/{
 table=gensub(/^CREATE TABLE (.*) [(]/,"\\1",1)
}
/^\t(.*) (INT.*|BIGINT) .*DEFAULT nextval/{
 sequencename=gensub(/^\t.*DEFAULT nextval[(]\047(.*)\047(::REGCLASS)?[)]/,"\\1",1)
 fieldname=gensub(/^\t,?(.*)( INT.*| BIGINT).*/,"\\1",1)
 linksequences=linksequences"alter sequence "sequencename" owned by "table"."fieldname";\n"
 linksequences=linksequences"SELECT SETVAL(\047"sequencename"\047, COALESCE(MAX("fieldname"), 1) ) FROM "table";\n"
}
/^\t(.*) (INT.*|BIGINT) .*DEFAULT unique_rowid/ && !/NOT VISIBLE/{
 fieldname=gensub(/^\t,?(.*)( INT.*| BIGINT).*/,"\\1",1)
 fieldtype=gensub(/^\t.* (INT.*|BIGINT) .*/,"\\1",1)
 tablename=gensub(/.*\.\042?([^\042]*)\042?/,"\\1",1,table)
 sequencename="public."gensub(/([^\042]*\042?[^\042]*)(\042?$)/,"\\1_"tablename"_seq\\2",1,fieldname)
 linksequences=linksequences"create sequence "sequencename" AS "fieldtype" MINVALUE 1 INCREMENT 1 START 1;\n"
 linksequences=linksequences"alter sequence "sequencename" owned by "table"."fieldname";\n"
 linksequences=linksequences"SELECT SETVAL(\047"sequencename"\047, COALESCE(MAX("fieldname"), 1) ) FROM "table";\n"
 $0=gensub(/(.*)(DEFAULT unique_rowid[()]*)(.*)$/,"\\1\\3",1)
}
/^\t*,(UNIQUE )?INDEX/{
 indexes=indexes"\n"gensub(/ STORING /," INCLUDE ",1,gensub(/^\t*,(UNIQUE )?(INDEX)([^(]+)(.*)( STORING)?(.*)$/,"create \\1\\2 \\3 on "table" \\4 \\5 \\6;",1))
 $0=gensub(/(^\t*),(.*)$/,"\\1--\\2",1)
}
# validate constraints at creation
/^ALTER TABLE.*ADD CONSTRAINT.*/{
 $0=gensub(/(.*)(NOT VALID)?(;)$/,"\\1\\3",1)
 {print > "ref-"FILENAME}
 $0="--"$0
}
/^ALTER TABLE.*VALIDATE CONSTRAINT.*;$/{
$0="--"$0
}
# print that to the create table file and ignore NOT VISIBLE lines
!/NOT VISIBLE/{print > "tab-"FILENAME}
END{
print indexes > "ind-"FILENAME
print linksequences > "link-"FILENAME
}
' $ddlfilename

awk '
/_.*_seq/{
  $0="namedeleteme"
}
/[(].*rows[)]/{
  $0="namedeleteme"
}
!/namedeleteme/{ print > FILENAME }
' $alltablesfilename

popd

while read table;do
  if [[ $table == "directus_activity" ]];then
    continue
  fi
  if [[ $table == "directus_revisions" ]];then
    continue
  fi
  psql $1 -At -F $fieldDelimiterChar -R $recordDelimiterChar -c "select * from public.\"$table\"" > "./$foldername/$database-$table.csv"
  truncate -s -1 "./$foldername/$database-$table.csv"
  node process-csv.js "public.\"$table\"" "./$foldername/$database-$table.csv"
done <./$foldername/$alltablesfilename

cp reset-sequences.sql $foldername

pushd $foldername

rolePassword=$(head -c 18 /dev/urandom | base64 | awk '{ print substr(gensub(/[^a-zA-Z0-9]/, "", "g"),1,20) }')
cat << EOF > $database-create-role-and-db.sql
CREATE ROLE "$database" WITH LOGIN PASSWORD '$rolePassword';

CREATE DATABASE "$database"
WITH OWNER "$database"
ENCODING 'UTF8'
LC_COLLATE = 'es_ES.utf8'
LC_CTYPE = 'es_ES.utf8'
TEMPLATE template0;

GRANT ALL PRIVILEGES ON DATABASE "$database" TO "$database";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$database";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$database";
EOF


cat << EOF > $database-restore.sh
#!/bin/bash
psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -ef $createtypes > $createtypes.log
psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -ef tab-$ddlfilename > tab-$ddlfilename.log
while read table;do
  psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -f "$database-\$table.sql"
done <./$alltablesfilename
psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -ef ind-$ddlfilename > ind-$ddlfilename.log
psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -ef ref-$ddlfilename > ref-$ddlfilename.log
psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -ef link-$ddlfilename > link-$ddlfilename.log
# rm -rf *.sql *.csv
EOF

chmod +x $database-restore.sh

popd
