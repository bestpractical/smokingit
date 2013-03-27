use Plack::Builder;
use Jifty;
Jifty->new;

builder {
    enable "CrossOrigin",
       origins => [
           "http://smokingit.bestpractical.com",
           "https://tickets.bestpractical.com",
           "http://localhost:8008"
       ],
       methods => ["GET"];

    Jifty->handler->psgi_app;
};
