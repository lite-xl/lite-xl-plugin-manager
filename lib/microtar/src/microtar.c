/*
 * Copyright (c) 2017 rxi
 * Copyright (c) 2024 Gaspartcho
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to
 * deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 * sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>

#include "microtar.h"

typedef struct {
	// Original tar header fields
	char file_path[100];
	char file_mode[8];
	char owner_user_id[8];
	char owner_group_id[8];
	char file_size[12];
	char file_mtime[12];
	char header_checksum[8];
	char file_type;
	char link_path[100];

	// New UStar fields
	char magic_bytes[6];
	char version[2];
	char owner_user_name[32];
	char owner_group_name[32];
	char device_major_number[8];
	char device_minor_number[8];
	char prefix[155];

	char padding[12];
} mtar_raw_header_t;


static unsigned round_up(unsigned n, unsigned incr) {
  return n + (incr - n % incr) % incr;
}


static unsigned checksum(const mtar_raw_header_t* rh) {
  unsigned i;
  unsigned char *p = (unsigned char*) rh;
  unsigned res = 256;
  for (i = 0; i < offsetof(mtar_raw_header_t, header_checksum); i++) {
    res += p[i];
  }
  for (i = offsetof(mtar_raw_header_t, file_type); i < sizeof(*rh); i++) {
    res += p[i];
  }
  return res;
}


static int tread(mtar_t *tar, void *data, unsigned size) {
  int err = tar->read(tar, data, size);
  tar->pos += size;
  return err;
}


static int twrite(mtar_t *tar, const void *data, unsigned size) {
  int err = tar->write(tar, data, size);
  tar->pos += size;
  return err;
}


static int write_null_bytes(mtar_t *tar, int n) {
  int i, err;
  char nul = '\0';
  for (i = 0; i < n; i++) {
    err = twrite(tar, &nul, 1);
    if (err) {
      return err;
    }
  }
  return MTAR_ESUCCESS;
}

static int read_filename(char *dest, const char *name, const char *prefix) {
  // If there's no prefix, use name directly
  if (prefix[0] == '\0') {
    strcpy(dest, name);
    dest[100] = '\0';
    return MTAR_ESUCCESS;
  }

  // If there is a prefix, the path is: <prefix> '/' <path>
  strcpy(dest, prefix);
  strcat(dest, "/");
  strcat(dest, name);
  dest[256] = '\0';

  return MTAR_ESUCCESS;
}


static int raw_to_header(mtar_header_t *h, const mtar_raw_header_t *rh) {
  unsigned chksum1, chksum2;

  /* If the checksum starts with a null byte we assume the record is NULL */
  if (*rh->header_checksum == '\0') {
    return MTAR_ENULLRECORD;
  }

  /* Build and compare checksum */
  chksum1 = checksum(rh);
  sscanf(rh->header_checksum, "%o", &chksum2);
  if (chksum1 != chksum2) {
    return MTAR_EBADCHKSUM;
  }

  /* Load raw header into header */
  sscanf(rh->file_mode, "%o", &h->mode);
  sscanf(rh->owner_user_id, "%o", &h->owner);
  sscanf(rh->file_size, "%o", &h->size);
  sscanf(rh->file_mtime, "%o", &h->mtime);
  h->type = rh->file_type;
  read_filename(h->name, rh->file_path, rh->prefix);
  read_filename(h->linkname, rh->link_path, rh->prefix);

  return MTAR_ESUCCESS;
}


static int header_to_raw(mtar_raw_header_t *rh, const mtar_header_t *h) {
  unsigned chksum;

  /* Load header into raw header */
  memset(rh, 0, sizeof(*rh));
  sprintf(rh->file_mode  , "%o", h->mode);
  sprintf(rh->owner_user_id, "%o", h->owner);
  sprintf(rh->file_size, "%o", h->size);
  sprintf(rh->file_mtime, "%o", h->mtime);
  rh->file_type = h->type ? h->type : MTAR_TREG;
  strcpy(rh->file_path, h->name);
  strcpy(rh->link_path, h->linkname);


  /* Calculate and write checksum */
  chksum = checksum(rh);
  sprintf(rh->header_checksum, "%06o", chksum);
  rh->header_checksum[7] = ' ';

  return MTAR_ESUCCESS;
}


const char* mtar_strerror(int err) {
  switch (err) {
    case MTAR_ESUCCESS     : return "success";
    case MTAR_EFAILURE     : return "failure";
    case MTAR_EOPENFAIL    : return "could not open";
    case MTAR_EREADFAIL    : return "could not read";
    case MTAR_EWRITEFAIL   : return "could not write";
    case MTAR_ESEEKFAIL    : return "could not seek";
    case MTAR_EBADCHKSUM   : return "bad checksum";
    case MTAR_ENULLRECORD  : return "null record";
    case MTAR_ENOTFOUND    : return "file not found";
  }
  return "unknown error";
}


static int file_write(mtar_t *tar, const void *data, unsigned size) {
  unsigned res = fwrite(data, 1, size, tar->stream);
  return (res == size) ? MTAR_ESUCCESS : MTAR_EWRITEFAIL;
}

static int file_read(mtar_t *tar, void *data, unsigned size) {
  unsigned res = fread(data, 1, size, tar->stream);
  return (res == size) ? MTAR_ESUCCESS : MTAR_EREADFAIL;
}

static int file_seek(mtar_t *tar, unsigned offset) {
  int res = fseek(tar->stream, offset, SEEK_SET);
  return (res == 0) ? MTAR_ESUCCESS : MTAR_ESEEKFAIL;
}

static int file_close(mtar_t *tar) {
  fclose(tar->stream);
  return MTAR_ESUCCESS;
}


int mtar_open(mtar_t *tar, const char *filename, const char *mode) {
  int err;
  mtar_header_t h;

  /* Init tar struct and functions */
  memset(tar, 0, sizeof(*tar));
  tar->write = file_write;
  tar->read = file_read;
  tar->seek = file_seek;
  tar->close = file_close;

  /* Assure mode is always binary */
  if ( strchr(mode, 'r') ) mode = "rb";
  if ( strchr(mode, 'w') ) mode = "wb";
  if ( strchr(mode, 'a') ) mode = "ab";
  /* Open file */
  tar->stream = fopen(filename, mode);
  if (!tar->stream) {
    return MTAR_EOPENFAIL;
  }
  /* Read first header to check it is valid if mode is `r` */
  if (*mode == 'r') {
    err = mtar_read_header(tar, &h);
    if (err != MTAR_ESUCCESS) {
      mtar_close(tar);
      return err;
    }
  }

  /* Return ok */
  return MTAR_ESUCCESS;
}


int mtar_close(mtar_t *tar) {
  return tar->close(tar);
}


int mtar_seek(mtar_t *tar, unsigned pos) {
  int err = tar->seek(tar, pos);
  tar->pos = pos;
  return err;
}


int mtar_rewind(mtar_t *tar) {
  tar->remaining_data = 0;
  tar->last_header = 0;
  return mtar_seek(tar, 0);
}


int mtar_next(mtar_t *tar) {
  int err, n;
  mtar_header_t h;
  /* Load header */
  err = mtar_read_header(tar, &h);
  if (err) {
    return err;
  }
  /* Seek to next record */
  n = round_up(h.size, 512) + sizeof(mtar_raw_header_t);
  return mtar_seek(tar, tar->pos + n);
}


int mtar_find(mtar_t *tar, const char *name, mtar_header_t *h) {
  int err;
  mtar_header_t header;
  /* Start at beginning */
  err = mtar_rewind(tar);
  if (err) {
    return err;
  }
  /* Iterate all files until we hit an error or find the file */
  while ( (err = mtar_read_header(tar, &header)) == MTAR_ESUCCESS ) {
    if ( !strcmp(header.name, name) ) {
      if (h) {
        *h = header;
      }
      return MTAR_ESUCCESS;
    }
    mtar_next(tar);
  }
  /* Return error */
  if (err == MTAR_ENULLRECORD) {
    err = MTAR_ENOTFOUND;
  }
  return err;
}


int mtar_read_header(mtar_t *tar, mtar_header_t *h) {
  int err;
  mtar_raw_header_t rh;
  /* Save header position */
  tar->last_header = tar->pos;
  /* Read raw header */
  err = tread(tar, &rh, sizeof(rh));
  if (err) {
    return err;
  }
  /* Seek back to start of header */
  err = mtar_seek(tar, tar->last_header);
  if (err) {
    return err;
  }
  /* Load raw header into header struct and return */
  return raw_to_header(h, &rh);
}


int mtar_update_header(mtar_header_t *h, mtar_header_t *oh) {
  if (oh->mode) h->mode = oh->mode;
  if (oh->owner) h->owner = oh->owner;
  if (oh->size) h->size = oh->size;
  if (oh->mtime) h->mtime = oh->mtime;
  if (oh->type) h->type = oh->type;
  
  if (oh->name[0] != '\0') strcpy(h->name, oh->name);
  if (oh->linkname[0] != '\0') strcpy(h->linkname, oh->linkname);

  return MTAR_ESUCCESS;
}


int mtar_clear_header(mtar_header_t *h){
  h->mode = 0;
  h->owner = 0;
  h->size = 0;
  h->mtime = 0;
  h->type = 0;
  bzero(h->name, strlen(h->name));
  bzero(h->linkname, strlen(h->linkname));
  
  return MTAR_ESUCCESS;
}


int mtar_read_data(mtar_t *tar, void *ptr, unsigned size) {
  int err;
  /* If we have no remaining data then this is the first read, we get the size,
   * set the remaining data and seek to the beginning of the data */
  if (tar->remaining_data == 0) {
    mtar_header_t h;
    /* Read header */
    err = mtar_read_header(tar, &h);
    if (err) {
      return err;
    }
    /* Seek past header and init remaining data */
    err = mtar_seek(tar, tar->pos + sizeof(mtar_raw_header_t));
    if (err) {
      return err;
    }
    tar->remaining_data = h.size;
  }
  /* Read data */
  err = tread(tar, ptr, size);
  if (err) {
    return err;
  }
  tar->remaining_data -= size;
  /* If there is no remaining data we've finished reading and seek back to the
   * header */
  if (tar->remaining_data == 0) {
    return mtar_seek(tar, tar->last_header);
  }
  return MTAR_ESUCCESS;
}


int mtar_write_header(mtar_t *tar, const mtar_header_t *h) {
  mtar_raw_header_t rh;
  /* Build raw header and write */
  header_to_raw(&rh, h);
  tar->remaining_data = h->size;
  return twrite(tar, &rh, sizeof(rh));
}


int mtar_write_file_header(mtar_t *tar, const char *name, unsigned size) {
  mtar_header_t h;
  /* Build header */
  memset(&h, 0, sizeof(h));
  strcpy(h.name, name);
  h.size = size;
  h.type = MTAR_TREG;
  h.mode = 0664;
  /* Write header */
  return mtar_write_header(tar, &h);
}


int mtar_write_dir_header(mtar_t *tar, const char *name) {
  mtar_header_t h;
  /* Build header */
  memset(&h, 0, sizeof(h));
  strcpy(h.name, name);
  h.type = MTAR_TDIR;
  h.mode = 0775;
  /* Write header */
  return mtar_write_header(tar, &h);
}


int mtar_write_data(mtar_t *tar, const void *data, unsigned size) {
  int err;
  /* Write data */
  err = twrite(tar, data, size);
  if (err) {
    return err;
  }
  tar->remaining_data -= size;
  /* Write padding if we've written all the data for this file */
  if (tar->remaining_data == 0) {
    return write_null_bytes(tar, round_up(tar->pos, 512) - tar->pos);
  }
  return MTAR_ESUCCESS;
}


int mtar_finalize(mtar_t *tar) {
  /* Write two NULL records */
  return write_null_bytes(tar, sizeof(mtar_raw_header_t) * 2);
}

