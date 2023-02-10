#!/bin/bash

uri=$1
database=$2

shouldStopOnError=${ON_ERROR_STOP:-0}

foldername=$(date +%Y%m%d%H%M%S)

fieldDelimiterChar=$(echo "AQ==" | base64 -d -w 0)
recordDelimiterChar=$(echo "Ag==" | base64 -d -w 0)

mkdir $foldername

ddlfilename=$database-ddl.sql

psql $1 -Ato ./$foldername/$ddlfilename -c "
show create all tables
"

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
# remove all reference to ordering in PRIMARY KEYs
/PRIMARY KEY/{
 $0=gensub(/(PRIMARY KEY.*?)([(].*?) .*?[)]/,"\\1\\2)","g")
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
}
' $ddlfilename

popd

all_tables=$(psql $1 -A -c "select name as namedeleteme from crdb_internal.tables where database_name = '$database'" | awk '
/_id_seq/{
  $0="namedeleteme"
}
/[(].*rows[)]/{
  $0="namedeleteme"
}
!/namedeleteme/{ print $0 }
')

for table in $all_tables;do
  psql $1 -At -F $fieldDelimiterChar -R $recordDelimiterChar -c "select * from public.\"$table\"" > ./$foldername/$database-$table.csv
  truncate -s -1 ./$foldername/$database-$table.csv
  node process-csv.js "public.\"$table\"" "./$foldername/$database-$table.csv"
done

pushd $foldername

cat << EOF > $database-restore.sh
#!/bin/bash
psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -ef tab-$ddlfilename > tab-$ddlfilename.log
all_tables="$all_tables"
for table in \$all_tables;do
  psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -f $database-\$table.sql
done
psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -ef ind-$ddlfilename > ind-$ddlfilename.log
psql \$1 -v ON_ERROR_STOP=$shouldStopOnError -ef ref-$ddlfilename > ref-$ddlfilename.log
rm -rf *.sql *.csv
EOF

chmod +x $database-restore.sh

popd
