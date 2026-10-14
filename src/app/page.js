import { createClient } from '@supabase/supabase-js';
export const dynamic = 'force-dynamic';

// Initialize the Supabase client
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const supabase = createClient(supabaseUrl, supabaseKey);

export default async function Home() {
  
  // Fetch all upcoming events from database table
  const { data: events, error } = await supabase
    .from('events')
    .select('*');

  if (error) {
    console.error("Error fetching events:", error.message);
  }

  // Render the styled data to the screen
  return (
    <main className="max-w-3xl mx-auto py-12 px-4 sm:px-6">
      <div className="border-b border-gray-200 pb-5 mb-8">
        <h1 className="text-3xl font-extrabold tracking-tight text-gray-900">
          NYC Muay Thai Event Feed
        </h1>
        <p className="mt-2 text-gray-500">
          The unified calendar for local smokers and major tri-state promotions.
        </p>
      </div>
      
      <div className="space-y-6">
        {events && events.length > 0 ? (
          events.map((event) => (
            <div key={event.id} className="bg-white border border-gray-200 rounded-xl p-6 shadow-sm hover:shadow-md transition-shadow">
              <div>
                <h2 className="text-xl font-bold text-gray-900">{event.promotion}</h2>
                <p className="text-gray-600 mt-2 leading-relaxed">{event.details}</p>
              </div>
              <div className="mt-6">
                <a 
                  href={event.url} 
                  target="_blank" 
                  rel="noopener noreferrer"
                  className="inline-flex items-center justify-center px-5 py-2.5 text-sm font-medium text-white bg-black rounded-lg hover:bg-gray-800 transition-colors"
                >
                  View Event Details
                </a>
              </div>
            </div>
          ))
        ) : (
          <div className="text-center py-12 border-2 border-dashed border-gray-300 rounded-xl">
            <p className="text-gray-500 font-medium">No upcoming events found in the database.</p>
          </div>
        )}
      </div>
    </main>
  );
}