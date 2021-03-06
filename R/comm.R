registerTwitterOAuth <- function(oauth) {
  require("ROAuth") || stop("ROAuth must be installed for ",
                            "OAuth functionality")
  if (!inherits(oauth, "OAuth"))
    stop("oauth argument must be of class OAuth")
  if (! oauth$getHandshakeComplete())
    stop("oauth has not completed its handshake")
  assign('oauth', oauth, envir=oauthCache)
  TRUE
}

hasOAuth <- function() {
  exists('oauth', envir=oauthCache)
}

getOAuth <- function() {
  if (!hasOAuth())
    stop("OAuth has not been registered for this session")
  get("oauth", envir=oauthCache)
}

## twitter API has multiple methods of handling paging issues, not to mention the search API
## has a completely different interface.  Trying to manage all of these below using one unified
## approach to actually sending the data back & receiving response and then providing multiple
## mechanisms to page
twFromJSON = function(json) {
  ## Will provide some basic error checking, as well as suppress
  ## warnings that always seem to come out of fromJSON, even
  ## in good cases. 
  out <- try(suppressWarnings(rjson:::fromJSON(json, unexpected.escape="skip")), silent=TRUE)
  if (inherits(out, "try-error")) {
    stop("Error: Malformed response from server, was not JSON.\n",
         "The most likely cause of this error is Twitter returning a character which\n",
         "can't be properly parsed by R. Generally the only remedy is to wait long\n",
         "enough for the offending character to disappear from searches (e.g. if\n",
         "using searchTwitter()).")
  }
  
  return(out)

}

doAPICall = function(cmd, params=NULL, method="GET", url=NULL, retryCount=5, 
                     blockOnRateLimit=FALSE, ...) {
  recall_func = function(count) {
    return(doAPICall(cmd, params=params, method=method, url=url, retryCount=count,
                     blockOnRateLimit=blockOnRateLimit, ...))
  }
  
  if (is.null(url)) {
    url <- getAPIStr(cmd)
  }

  if (!hasOAuth()) {
    stop("OAuth authentication is required with Twitter's API v1.1")
  }
  
  oauth = getOAuth()
  out = try(oauth$OAuthRequest(url, params, method, ...), silent=TRUE)
  if (inherits(out, "try-error")) {
    error_message = gsub("\\r\\n", "", attr(out, "condition")[["message"]])
    print(error_message)
    if (error_message %in% c("Internal Server Error", "Service Unavailable")) {
      print(paste("This error is likely transient, retrying up to", retryCount, "more times ..."))
      ## These are typically fail whales or similar such things
      Sys.sleep(1)
      return(recall_func(retryCount - 1))      
    } else if ((error_message == "Too Many Requests") && (blockOnRateLimit)) {
      ## We're rate limited. Wait a while and try again
      print("Rate limited .... blocking for a minute ...")
      Sys.sleep(60)
      return(recall_func(retryCount))      
    } else {
      stop("Error: ", error_message)
    }
  } 
 
  json = twFromJSON(out)

  return(json)  
}

setRefClass('twAPIInterface',
            fields = list(
              maxResults = 'integer'
              ),
            methods = list(
              initialize=function(...) {
                maxResults <<- 100L
                callSuper(...)
                .self
              },
              twFromJSON = twFromJSON,
              doAPICall = doAPICall
              )
            )


tint <- getRefClass('twAPIInterface')
tint$accessors(names(tint$fields()))
twInterfaceObj <- tint$new()


doPagedAPICall = function(cmd, num, params=NULL, method='GET', ...) {
  if (num <= 0)
    stop('num must be positive')
  else
    num <- as.integer(num)

  maxResults <- twInterfaceObj$getMaxResults()
  page <- 1
  total <- num
  count <- ifelse(num < maxResults, num, maxResults)
  jsonList <- list()
  params[['count']] <- count
  while (total > 0) {
    params[['page']] <- page
    jsonList <- c(jsonList,
                  twInterfaceObj$doAPICall(cmd, params, method, ...))
    total <- total - count
    page <- page + 1
  }
  jLen <- length(jsonList)
  if ((jLen > 0) && (jLen > num))
    jsonList <- jsonList[1:num]
  jsonList
}

doCursorAPICall = function(cmd, type, num=NULL, params=NULL, method='GET', ...) {
  cursor <- -1
  if (!is.null(num)) {
    if (num <= 0)
      stop("num must be positive")
    else
      num <- as.integer(num)
  }
  vals <- character()
  while(cursor != 0) {
    params[['cursor']] <- cursor
    curResults <- twInterfaceObj$doAPICall(cmd, params, method, ...)
    vals <- c(vals, curResults[[type]])
    if ((!is.null(num)) && (length(vals) >= num))
      break
    cursor <- curResults[['next_cursor_str']]
  }
  if ((!is.null(num)) && (length(vals) > num))
    vals <- vals[1:num]
  vals
}

doRppAPICall = function(cmd, num, params, ...) {
  if (! 'q' %in% names(params))
    stop("parameter 'q' must be supplied")
  maxResults <- twInterfaceObj$getMaxResults()
  params[['result_type']] <- 'recent'
  params[['count']] <- ifelse(num < maxResults, num, maxResults)
    
  curDiff <- num
  jsonList <- list()
  while (curDiff > 0) {
    fromJSON <- twInterfaceObj$doAPICall(cmd, params, 'GET', ...)
    newList <- fromJSON$statuses
    jsonList <- c(jsonList, newList)
    curDiff <- num - length(jsonList)
    if ((curDiff > 0) && ("search_metadata" %in% names(fromJSON)) && ("max_id_str" %in% names(fromJSON[["search_metadata"]]))) {
      params[["max_id"]] = fromJSON[["search_metadata"]][["max_id_str"]]
    }
  }
  
  if (length(jsonList) > num) {
    jsonList = jsonList[seq_len(num)]
  }
  
  return(jsonList)
}

twitterDateToPOSIX <- function(dateStr) {
  ## In typical twitter fashion, there are multiple ways that they
  ## spit dates back at us.  First, let's take a look at unix
  ## epoch time, and then try a few data string formats
  dateInt <- suppressWarnings(as.numeric(dateStr))

  ## Locale must be set to something american-y in order to properly
  ## parse the Twitter dates. Get the current LC_TIME, reset it on
  ## exit and then change the locale
  curLocale <- Sys.getlocale("LC_TIME")
  on.exit(Sys.setlocale("LC_TIME", curLocale), add=TRUE)
  Sys.setlocale("LC_TIME", "C")
  
  if (!is.na(dateInt)) {
    posDate <- as.POSIXct(dateInt, tz='UTC', origin='1970-01-01')
  } else {
    posDate <- as.POSIXct(dateStr, tz='UTC',
                          format="%a %b %d %H:%M:%S +0000 %Y")
    ## try again if necessary
    if (is.na(posDate))
      posDate <- as.POSIXct(dateStr, tz='UTC',
                            format="%a, %d %b %Y %H:%M:%S +0000")
  }
  ## might still be NA, but we tried
  return(posDate)
}


