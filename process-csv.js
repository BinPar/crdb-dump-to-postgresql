const fs = require('fs');
const es = require('./event-stream');

const RECORD_DELIMITER = String.fromCharCode(2);
const FIELD_DELIMITER = String.fromCharCode(1);

const table = process.argv[2];
const file = process.argv[3];

// let fileContent = fs.readFileSync(file, 'utf-8');

const splitInsert = process.env.SPLIT_INSERT
  ? parseInt(process.env.SPLIT_INSERT, 10)
  : 10;
let processedNumber = 0;
const writeStream = fs.createWriteStream(`${file.replace('.csv', '.sql')}`);
const s = fs
  .createReadStream(file)
  .pipe(es.split(RECORD_DELIMITER))
  .pipe(
    es
      .mapSync(function (recordString) {
        // pause the readstream
        s.pause();
        const fields = recordString.split(FIELD_DELIMITER);
        if (processedNumber % splitInsert === 0) {
          writeStream.write(
            `${processedNumber !== 0 ? ';\n' : ''}INSERT INTO ${table} VALUES`,
          );
        }
        let fieldsString = '';
        for (let j = 0; j < fields.length; j += 1) {
          const field = fields[j];
          if (field === undefined || field === null || field === '') {
            fieldsString = `${fieldsString}${j === 0 ? '' : ', '}NULL`;
          } else if (field === 'true' || field === 'false') {
            fieldsString = `${fieldsString}${j === 0 ? '' : ', '}${field}`;
          } else {
            fieldsString = `${fieldsString}${
              j === 0 ? '' : ', '
            }'${field.replace(/'/g, "''")}'`;
          }
        }
        writeStream.write(`${processedNumber % splitInsert === 0 ? '' : ','}
  (${fieldsString})`);
        processedNumber += 1;
        // resume the readstream, possibly from a callback
        s.resume();
      })
      .on('error', function (err) {
        console.log('Error while reading file.', err);
        writeStream.destroy(err);
      })
      .on('end', function () {
        console.log(
          `File ${file} process completed, record processed: ${processedNumber}`,
        );
        writeStream.close();
      }),
  );
